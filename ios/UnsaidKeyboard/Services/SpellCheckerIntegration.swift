//
//  SpellCheckerIntegration.swift
//  UnsaidKeyboard
//
//  Service wrapper for spell checking functionality (optimized + intentional typing)
//

import Foundation
import UIKit

protocol SpellCheckerIntegrationDelegate: AnyObject {
    func didUpdateSpellingSuggestions(_ suggestions: [String])
    func didApplySpellCorrection(_ correction: String, original: String)
}

@MainActor
final class SpellCheckerIntegration {
    weak var delegate: SpellCheckerIntegrationDelegate?
    
    private let spellChecker = LightweightSpellChecker.shared
    private let correctionBoundaries = Set<Character>([" ", "\n", ".", ",", "!", "?", ":", ";"])
    
    init() {}
    
    // MARK: - Public Interface
    
    /// Refresh suggestions as the user types (mid-token).
    /// Uses a cheap async path and coalesces in the checker to keep the extension responsive.
    func refreshSpellCandidates(for text: String) {
        guard let lastWord = LightweightSpellChecker.lastToken(in: text),
              !lastWord.isEmpty,
              shouldCheckSpelling(for: lastWord) else {
            delegate?.didUpdateSpellingSuggestions([])
            return
        }
        
        // Lightweight async: the checker coalesces internally.
        spellChecker.quickSpellCheckAsync(text: text) { [weak self] suggestions in
            guard let self = self else { return }
            Task { @MainActor in
                self.delegate?.didUpdateSpellingSuggestions(Array(suggestions.prefix(3)))
            }
        }
    }
    
    /// Apply a tapped candidate from your strip.
    func applySpellCandidate(_ candidate: String, in proxy: UITextDocumentProxy) {
        guard let before = proxy.documentContextBeforeInput,
              let lastWord = LightweightSpellChecker.lastToken(in: before),
              !lastWord.isEmpty else { return }
        
        // Replace the last word
        for _ in 0..<lastWord.count { proxy.deleteBackward() }
        proxy.insertText(candidate)
        
        // Track for undo & learning
        spellChecker.applyInlineCorrection(candidate, originalWord: lastWord)
        spellChecker.recordAcceptedCorrection(original: lastWord, corrected: candidate)
        UndoManagerLite.shared.record(original: lastWord, corrected: candidate)
        
        delegate?.didApplySpellCorrection(candidate, original: lastWord)
    }
    
    /// Attempt commit-time autocorrect when the user types a boundary (space/punctuation/newline).
    func autocorrectLastWordIfNeeded(afterTyping boundary: Character, in proxy: UITextDocumentProxy) {
        // Only run on commit boundaries; never during mid-word typing
        guard correctionBoundaries.contains(boundary) else { return }
        
        let before = proxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return }
        
        // If the last character actually is the boundary, temporarily remove it
        var poppedBoundary = false
        if let lastChar = before.last, lastChar == boundary {
            proxy.deleteBackward()
            poppedBoundary = true
        }
        
        let coreBefore = proxy.documentContextBeforeInput ?? ""
        guard let lastWord = LightweightSpellChecker.lastToken(in: coreBefore),
              !lastWord.isEmpty,
              shouldAutoCorrect(lastWord) else {
            if poppedBoundary { proxy.insertText(String(boundary)) }
            return
        }
        
        // Peek "next" token for bigram scoring if present (often empty at commit)
        let after = proxy.documentContextAfterInput ?? ""
        let nextToken = LightweightSpellChecker.lastToken(in: after)
        
        // Unified decision: Apple-like behavior at commit boundary
        let decision = spellChecker.decide(
            for: lastWord,
            prev: nil,
            next: nextToken,
            langOverride: nil,
            isOnCommitBoundary: true
        )
        
        guard decision.applyAuto, let replacement = decision.replacement, replacement != lastWord else {
            // No auto — just put boundary back if we popped it
            if poppedBoundary { proxy.insertText(String(boundary)) }
            return
        }
        
        // Replace the last word, then reinsert boundary
        for _ in 0..<lastWord.count { proxy.deleteBackward() }
        proxy.insertText(replacement)
        if poppedBoundary { proxy.insertText(String(boundary)) }
        
        // Track for undo / acceptance learning
        spellChecker.applyInlineCorrection(replacement, originalWord: lastWord)
        spellChecker.recordAutocorrection(lastWord) // intentionally a no-op regarding "intentional"
        spellChecker.recordAcceptedCorrection(original: lastWord, corrected: replacement)
        UndoManagerLite.shared.record(original: lastWord, corrected: replacement)
        
        delegate?.didApplySpellCorrection(replacement, original: lastWord)
    }
    
    func undoLastCorrection(in proxy: UITextDocumentProxy) -> Bool {
        return UndoManagerLite.shared.tryUndo(in: proxy)
    }
    
    // MARK: - Private Helpers
    
    private func shouldCheckSpelling(for word: String) -> Bool {
        let lower = word.lowercased()
        // Skip URLs, mentions, hashtags, likely IDs/paths
        if lower.hasPrefix("@") || lower.hasPrefix("#") || lower.contains("http") { return false }
        if lower.contains("/") || lower.contains("_") { return false }
        return true
    }
    
    private func shouldAutoCorrect(_ word: String) -> Bool {
        let lower = word.lowercased()
        // Skip URLs, mentions, hashtags, likely IDs/paths
        if lower.hasPrefix("@") || lower.hasPrefix("#") || lower.contains("http") { return false }
        if lower.contains("/") || lower.contains("_") { return false }
        return true
    }
}

// MARK: - UndoManagerLite for autocorrect undo
final class UndoManagerLite {
    static let shared = UndoManagerLite()
    private var last: (original: String, corrected: String, chars: Int)?
    
    private init() {}
    
    func record(original: String, corrected: String) {
        last = (original, corrected, corrected.count)
    }
    
    /// Undo the most recent auto- or tap-applied correction.
    /// Also marks the original word as "intentional", so if the user retypes it,
    /// the spell checker will *not* autocorrect it again (iOS-like behavior).
    func tryUndo(in proxy: UITextDocumentProxy) -> Bool {
        guard let l = last else { return false }
        for _ in 0..<l.chars { proxy.deleteBackward() }
        proxy.insertText(l.original)
        
        // Mark as intentional so subsequent re-entries won't autocorrect
        LightweightSpellChecker.shared.recordIntentionalWord(l.original)
        
        last = nil
        return true
    }
}
