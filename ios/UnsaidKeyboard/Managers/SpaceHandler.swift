//
//  SpaceHandler.swift
//  UnsaidKeyboard
//
//  iOS-native double-space-to-period with enhanced authenticity
//

import Foundation
import UIKit

// MARK: - Time Source Protocol (for testability)
protocol TimeSource {
    func now() -> CFTimeInterval
}

struct DefaultTimeSource: TimeSource {
    func now() -> CFTimeInterval { CACurrentMediaTime() }
}

@MainActor
protocol SpaceHandlerDelegate: AnyObject {
    func insertText(_ text: String)
    func getTextDocumentProxy() -> UITextDocumentProxy?
    // Optional: haptic if you want (not required)
    func hapticLight()
    func requestSentenceAutoCap()   // NEW
}

@MainActor
final class SpaceHandler {
    weak var delegate: SpaceHandlerDelegate?
    private let timeSource: TimeSource

    // Double-space configuration
    private var lastSpaceTapTime: CFTimeInterval = 0
    private let doubleSpaceWindow: CFTimeInterval = 0.35

    init(timeSource: TimeSource = DefaultTimeSource()) {
        self.timeSource = timeSource
    }

    // MARK: - Public

    func setupSpaceButton(_ button: UIButton) {
        // No gestures needed — we’re lightweight.
    }

    /// Call this on space key tap (touchUpInside or key action)
    func handleSpaceKey() {
        let now = timeSource.now()
        let delta = now - lastSpaceTapTime

        if delta <= doubleSpaceWindow, shouldApplyDoubleSpacePeriod() {
            applyDoubleSpacePeriod()
            lastSpaceTapTime = 0 // Reset to prevent triple-tap retriggering
            // Haptic is handled by KeyboardController to avoid double buzz
        } else {
            delegate?.insertText(" ")
            lastSpaceTapTime = now
        }
    }

        // MARK: - Double-space logic

    private func shouldApplyDoubleSpacePeriod() -> Bool {
        guard let proxy = delegate?.getTextDocumentProxy() else { return false }
        
        let before = proxy.documentContextBeforeInput ?? ""
        guard before.last == " " else { return false }
        let trimmedBefore = before.dropLast() // remove the last space just typed

        guard let lastNonSpace = trimmedBefore.last, !lastNonSpace.isWhitespace else { return false }
        
        // Only fire when cursor is at word end
        if !caretAtWordEnd(proxy) { return false }

        // Handle closing delimiters - we'll place period before them in applyDoubleSpacePeriod
        let closingDelimiters: Set<Character> = [")", "]", "}", "\"", "'"]
        if closingDelimiters.contains(lastNonSpace) { return true }
        
        // Don't add if we already ended a sentence
        let terminalSet: Set<Character> = [".", "!", "?", "…", ":", ";", "—", "–"]
        if terminalSet.contains(lastNonSpace) { return false }
        
        // Check for ellipsis
        let tail = String(trimmedBefore.suffix(64)).lowercased()
        if tail.hasSuffix("...") { return false }
        
        // Avoid URLs/emails and abbreviations
        if looksLikeURLorEmail(tail) { return false }
        if endsWithCommonAbbreviation(tail) { return false }

        return true
    }
    
    private func caretAtWordEnd(_ proxy: UITextDocumentProxy) -> Bool {
        let after = proxy.documentContextAfterInput ?? ""
        guard let first = after.first else { return true } // nothing after caret
        return first.isWhitespace || first.isPunctuation
    }

    private func applyDoubleSpacePeriod() {
        guard let proxy = delegate?.getTextDocumentProxy() else {
            delegate?.insertText(" ")
            return
        }
        
        // Delete the last typed space
        proxy.deleteBackward()

        // If the last visible char is a closing delimiter, insert ". " before it
        let before = proxy.documentContextBeforeInput ?? ""
        if let last = before.last, ")]}\"'".contains(last) {
            // Remove the delimiter, insert ". ", then put the delimiter back
            proxy.deleteBackward()
            delegate?.insertText(". ")
            delegate?.insertText(String(last))
        } else {
            delegate?.insertText(". ")
        }

        delegate?.requestSentenceAutoCap()
    }

    // MARK: - Heuristics

    private func looksLikeURLorEmail(_ s: String) -> Bool {
        let tail = s.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        
        // Crude email: word@word.tld
        if tail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { 
            return true 
        }
        
        // Crude URL: scheme:// or bare domain.tld
        if tail.hasPrefix("http://") || tail.hasPrefix("https://") { 
            return true 
        }
        
        if tail.range(of: #"\b[a-z0-9.-]+\.(com|org|net|edu|io|gov|co)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { 
            return true 
        }
        
        return false
    }

    private func endsWithCommonAbbreviation(_ s: String) -> Bool {
        guard let lastWord = s.split(whereSeparator: \.isWhitespace).last else { return false }
        let base = String(lastWord).trimmingCharacters(in: .punctuationCharacters).lowercased()
        
        // US-centric starter set; consider locale-switching later
        let abbr: Set<String> = [
            "mr", "mrs", "ms", "dr", "vs", "etc", "inc", "ltd", "jr", "sr",
            "st", "rd", "ave", "blvd", "eg", "ie", "us", "uk",
            "a.m", "p.m", "am", "pm", "phd", "mba", "md", "prof", "rev",
            "gen", "col", "capt", "sgt", "corp", "pvt", "dept", "govt",
            "min", "max", "approx", "est", "misc", "temp", "info", "no"
        ]
        return abbr.contains(base)
    }
}

// MARK: - Small Character helpers
private extension Character {
    var isWhitespace: Bool { unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } }
}
