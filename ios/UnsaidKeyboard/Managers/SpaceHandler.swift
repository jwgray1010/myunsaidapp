//
//  SpaceHandler.swift
//  UnsaidKeyboard
//
//  Lightweight: ONLY double-space period. No trackpad.
//

import Foundation
import UIKit

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

    // Double-space configuration
    private var lastSpaceTapTime: CFTimeInterval = 0
    private let doubleSpaceWindow: CFTimeInterval = 0.35

    init() {}

    // MARK: - Public

    func setupSpaceButton(_ button: UIButton) {
        // No gestures needed — we’re lightweight.
    }

    /// Call this on space key tap (touchUpInside or key action)
    func handleSpaceKey() {
        let now = CACurrentMediaTime()
        let delta = now - lastSpaceTapTime

        if delta <= doubleSpaceWindow, shouldApplyDoubleSpacePeriod() {
            applyDoubleSpacePeriod()
            // Haptic is handled by KeyboardController to avoid double buzz
        } else {
            delegate?.insertText(" ")
        }

        lastSpaceTapTime = now
    }

    // MARK: - Double-space logic

    private func shouldApplyDoubleSpacePeriod() -> Bool {
        guard let proxy = delegate?.getTextDocumentProxy() else { return false }
        let before = proxy.documentContextBeforeInput ?? ""

        // Need at least "X " before cursor where X is non-space
        guard let last = before.last, last == " " else { return false }
        let trimmedBefore = before.dropLast() // remove the last space just typed

        guard let lastNonSpace = trimmedBefore.last, !lastNonSpace.isWhitespace else { return false }

        // Avoid if already ending with sentence punctuation or closing delimiters
        let terminalSet: Set<Character> = [".","!","?","…",":",";","—","–",")","]","}", "\"","'","”","’"]
        if terminalSet.contains(lastNonSpace) { return false }

        // Avoid common abbreviations/URLs/emails at the end
        let tail = String(trimmedBefore.suffix(48)).lowercased()
        if looksLikeURLorEmail(tail) { return false }
        if endsWithCommonAbbreviation(tail) { return false }

        return true
    }

    private func applyDoubleSpacePeriod() {
        guard let proxy = delegate?.getTextDocumentProxy() else {
            delegate?.insertText(" ")
            return
        }
        // Replace the prior space with ". "
        proxy.deleteBackward()
        delegate?.insertText(". ")
        delegate?.requestSentenceAutoCap()   // NEW
    }

    // MARK: - Heuristics

    private func looksLikeURLorEmail(_ s: String) -> Bool {
        // Ultra-light checks for a keyboard context
        if s.contains("@") { return true }
        if s.contains("http://") || s.contains("https://") { return true }
        if s.contains(".com") || s.contains(".org") || s.contains(".net") { return true }
        if s.split(whereSeparator: \.isWhitespace).last?.contains(".") == true { return true }
        return false
    }

    private func endsWithCommonAbbreviation(_ s: String) -> Bool {
        guard let lastWord = s.split(whereSeparator: \.isWhitespace).last else { return false }
        let base = String(lastWord).trimmingCharacters(in: .punctuationCharacters)
        let abbr: Set<String> = ["mr","mrs","ms","dr","vs","etc","inc","ltd","jr","sr",
                                 "st","rd","ave","blvd","eg","ie","us","uk"]
        return abbr.contains(base)
    }
}

// MARK: - Small Character helpers
private extension Character {
    var isWhitespace: Bool { unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } }
}
