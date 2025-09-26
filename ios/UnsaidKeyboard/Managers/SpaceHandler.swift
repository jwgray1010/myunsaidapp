//
//  SpaceHandler.swift
//  UnsaidKeyboard
//
//  iOS-native double-space-to-period with boundary signaling and TimerHub grace
//

import Foundation
import UIKit
import QuartzCore

// MARK: - Time Source (testability)
protocol TimeSource { func now() -> CFTimeInterval }
struct DefaultTimeSource: TimeSource { func now() -> CFTimeInterval { CACurrentMediaTime() } }

// MARK: - Delegate
@MainActor
protocol SpaceHandlerDelegate: AnyObject {
    func insertText(_ text: String)
    func getTextDocumentProxy() -> UITextDocumentProxy?
    func hapticLight()
    func requestSentenceAutoCap()
}

// MARK: - Boundary type (optional signal to tone coordinator)
enum BoundaryKind { case word, sentence }

@MainActor
final class SpaceHandler {

    // MARK: - Public hooks
    weak var delegate: SpaceHandlerDelegate?

    /// Optional: set this from your KeyboardController to trigger tone analysis.
    /// Example:
    ///   spaceHandler.onBoundaryDetected = { [weak self] kind in
    ///       let text = self?.fullTextSnapshot() ?? ""
    ///       switch kind {
    ///       case .sentence: self?.toneCoordinator.scheduleImmediateFullTextAnalysis(fullText: text, triggerReason: "space->sentence")
    ///       case .word:     self?.toneCoordinator.scheduleFullTextAnalysis(fullText: text, triggerReason: "space->word", lastInserted: " ", isDeletion: false)
    ///       }
    ///   }
    var onBoundaryDetected: ((BoundaryKind) -> Void)?

    // MARK: - Config
    private let timeSource: TimeSource
    private let doubleSpaceWindow: CFTimeInterval = 0.35        // iOS-esque
    private let postSpaceGrace: TimeInterval = 0.10             // let autocorrect settle
    private let boundaryTailLookback = 4                        // chars to re-check after grace

    // MARK: - State
    private var lastSpaceTapTime: CFTimeInterval = 0
    private var spaceGraceToken: TimerToken?
    private var lastBoundaryCaretPosition: Int = -1

    // MARK: - Init
    init(timeSource: TimeSource = DefaultTimeSource()) {
        self.timeSource = timeSource
    }

    // MARK: - Wiring (kept for parity)
    func setupSpaceButton(_ button: UIButton) { /* no-op */ }

    // MARK: - Entry points
    /// Call from your key routing when user taps Space.
    func handleSpaceKey() {
        let now = timeSource.now()
        let delta = now - lastSpaceTapTime

        if delta <= doubleSpaceWindow, shouldApplyDoubleSpacePeriod() {
            applyDoubleSpacePeriod()                 // inserts ". " (with delimiter handling)
            lastSpaceTapTime = 0                     // reset to avoid triple-fire
            // Notify sentence boundary immediately (no grace needed; we just inserted the period)
            onBoundaryDetected?(.sentence)
            return
        }

        // Normal space: insert, then schedule a short grace before classifying boundary
        delegate?.insertText(" ")
        lastSpaceTapTime = now

        // Cancel any pending grace window and schedule a new one
        if let t = spaceGraceToken { TimerHub.shared.cancel(token: t) }
        spaceGraceToken = TimerHub.shared.schedule(after: postSpaceGrace, target: self) { me in
            { me.evaluatePostSpaceBoundary() }
        }
    }

    /// Optional: call from your backspace handler when the user deletes a character.
    /// If a space is deleted, we consider it a (reverse) word-edge boundary.
    func handleBackspaceDeletedCharacter(_ deleted: Character) {
        guard deleted == " " else { return }
        guard let proxy = delegate?.getTextDocumentProxy() else { return }

        let beforeLen = (proxy.documentContextBeforeInput ?? "").count
        // Gate duplicates at the exact same caret position
        guard beforeLen != lastBoundaryCaretPosition else { return }
        lastBoundaryCaretPosition = beforeLen

        onBoundaryDetected?(.word)
    }

    // MARK: - Post-space classification (after grace)
    private func evaluatePostSpaceBoundary() {
        guard let proxy = delegate?.getTextDocumentProxy() else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let caretPos = before.count

        // Prevent double firing at same caret position
        guard caretPos != lastBoundaryCaretPosition else { return }

        let tail = String(before.suffix(boundaryTailLookback))
        let sentenceEnders: Set<Character> = [".", "!", "?", "\n", "…"]

        if let last = tail.last, sentenceEnders.contains(last) {
            lastBoundaryCaretPosition = caretPos
            onBoundaryDetected?(.sentence)
            return
        }

        // Word boundary: exactly one trailing space, and preceding char is alnum
        if tail.hasSuffix(" ") && !tail.hasSuffix("  ") {
            if let prev = tail.dropLast().last, prev.isLetter || prev.isNumber {
                lastBoundaryCaretPosition = caretPos
                onBoundaryDetected?(.word)
            }
        }
    }

    // MARK: - Double-space logic
    private func shouldApplyDoubleSpacePeriod() -> Bool {
        guard let proxy = delegate?.getTextDocumentProxy() else { return false }

        let before = proxy.documentContextBeforeInput ?? ""
        guard before.last == " " else { return false }           // last char must be the space we just typed

        let trimmedBefore = before.dropLast()                    // remove the just-typed space
        guard let lastNonSpace = trimmedBefore.last, !lastNonSpace.isWhitespace else { return false }

        // Only fire when caret is truly at a word end
        guard caretAtWordEnd(proxy) else { return false }

        // Don’t add a period if we already ended the sentence
        let terminalSet: Set<Character> = [".", "!", "?", "…", ":", ";", "—", "–"]
        if terminalSet.contains(lastNonSpace) { return false }

        // Avoid ellipses
        let tail = String(trimmedBefore.suffix(64)).lowercased()
        if tail.hasSuffix("...") { return false }

        // Avoid URLs/emails/abbreviations
        if looksLikeURLorEmail(tail) { return false }
        if endsWithCommonAbbreviation(tail) { return false }

        return true
    }

    private func applyDoubleSpacePeriod() {
        guard let proxy = delegate?.getTextDocumentProxy() else {
            delegate?.insertText(" ")
            return
        }

        // Remove the last typed space
        proxy.deleteBackward()

        // If we’re right after a closing delimiter, insert the period *before* it.
        let before = proxy.documentContextBeforeInput ?? ""
        if let last = before.last, ")]}\"'".contains(last) {
            proxy.deleteBackward()
            delegate?.insertText(". ")
            delegate?.insertText(String(last))
        } else {
            delegate?.insertText(". ")
        }

        delegate?.requestSentenceAutoCap()
    }

    // MARK: - Heuristics
    private func caretAtWordEnd(_ proxy: UITextDocumentProxy) -> Bool {
        let after = proxy.documentContextAfterInput ?? ""
        guard let first = after.first else { return true }       // nothing after caret ⇒ word end
        return first.isWhitespace || first.isPunctuation
    }

    private func looksLikeURLorEmail(_ s: String) -> Bool {
        let tail = s.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""

        // Crude email: word@word.tld
        if tail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { return true }

        // Crude URL: scheme:// or bare domain.tld
        if tail.hasPrefix("http://") || tail.hasPrefix("https://") { return true }
        if tail.range(of: #"\b[a-z0-9.-]+\.(com|org|net|edu|io|gov|co)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return true }

        return false
    }

    private func endsWithCommonAbbreviation(_ s: String) -> Bool {
        guard let lastWord = s.split(whereSeparator: \.isWhitespace).last else { return false }
        let base = String(lastWord).trimmingCharacters(in: .punctuationCharacters).lowercased()

        // US-centric starter set; consider locale switching later.
        let abbr: Set<String> = [
            "mr","mrs","ms","dr","vs","etc","inc","ltd","jr","sr",
            "st","rd","ave","blvd","eg","ie","us","uk",
            "a.m","p.m","am","pm","phd","mba","md","prof","rev",
            "gen","col","capt","sgt","corp","pvt","dept","govt",
            "min","max","approx","est","misc","temp","info","no"
        ]
        return abbr.contains(base)
    }
}

// MARK: - Character helpers
private extension Character {
    var isWhitespace: Bool { unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } }
}
