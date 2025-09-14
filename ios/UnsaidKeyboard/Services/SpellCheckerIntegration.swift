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
    
    // Micro-optimizations to avoid redundant work
    private var lastSuggestionsToken: String?
    private let trailingWindowLimit = 512 // keep the async path cheap
    
    init() {}

    // MARK: - Public Interface
    
    /// Refresh suggestions as the user types (mid-token).
    /// Uses a cheap async path and coalesces in the checker to keep the extension responsive.
    func refreshSpellCandidates(for fullText: String) {
        // Only look at the trailing slice to bound work and string bridging
        let text = fullText.suffix(trailingWindowLimit).description
        
        guard let lastWord = LightweightSpellChecker.lastToken(in: text),
              !lastWord.isEmpty,
              shouldCheckSpelling(for: lastWord) else {
            lastSuggestionsToken = nil
            delegate?.didUpdateSpellingSuggestions([])
            return
        }
        
        // If the token hasn't changed since the last call, skip the trip.
        if lastSuggestionsToken == lastWord {
            return
        }
        lastSuggestionsToken = lastWord
        
        // Lightweight async: the checker coalesces internally.
        spellChecker.quickSpellCheckAsync(text: text) { [weak self] suggestions in
            guard let self = self else { return }
            Task { @MainActor in
                // Only publish if we're still looking at the same token
                if self.lastSuggestionsToken == lastWord {
                    self.delegate?.didUpdateSpellingSuggestions(Array(suggestions.prefix(3)))
                }
            }
        }
    }
    
    /// Apply a tapped candidate from your strip.
    func applySpellCandidate(_ candidate: String, in proxy: UITextDocumentProxy) {
        guard let before = proxy.documentContextBeforeInput,
              let lastWord = LightweightSpellChecker.lastToken(in: before),
              !lastWord.isEmpty else { return }
        
        // Replace the last word (delete grapheme-by-grapheme; UITextDocumentProxy handles this safely)
        for _ in 0..<lastWord.count { proxy.deleteBackward() }
        proxy.insertText(candidate)
        
        // Track for undo & learning
        spellChecker.applyInlineCorrection(candidate, originalWord: lastWord)
        spellChecker.recordAcceptedCorrection(original: lastWord, corrected: candidate)
        UndoManagerLite.shared.record(original: lastWord, corrected: candidate)
        
        delegate?.didApplySpellCorrection(candidate, original: lastWord)
        
        // New token context; reset suggestion token to avoid stale UI replays
        lastSuggestionsToken = nil
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
        
        // Re-read context after pop (cheap)
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
            if poppedBoundary { proxy.insertText(String(boundary)) }
            return
        }
        
        // Replace the last word, then reinsert boundary (if we popped it)
        for _ in 0..<lastWord.count { proxy.deleteBackward() }
        proxy.insertText(replacement)
        if poppedBoundary { proxy.insertText(String(boundary)) }
        
        // Track for undo / acceptance learning
        spellChecker.applyInlineCorrection(replacement, originalWord: lastWord)
        spellChecker.recordAutocorrection(lastWord) // intentionally a no-op wrt "intentional"
        spellChecker.recordAcceptedCorrection(original: lastWord, corrected: replacement)
        UndoManagerLite.shared.record(original: lastWord, corrected: replacement)
        
        delegate?.didApplySpellCorrection(replacement, original: lastWord)
        
        // Fresh token context post-commit
        lastSuggestionsToken = nil
    }
    
    /// Forward traits -> checker (keeps behavior aligned with system prefs).
    func syncTraits(from proxy: UITextDocumentProxy) {
        spellChecker.syncFromTextTraits(proxy)
    }
    
    func undoLastCorrection(in proxy: UITextDocumentProxy) -> Bool {
        let ok = UndoManagerLite.shared.tryUndo(in: proxy)
        if ok {
            // After undo, token definitely changed; clear suggestion cache key
            lastSuggestionsToken = nil
        }
        return ok
    }
    
    // MARK: - Private Helpers
    
    private func shouldCheckSpelling(for word: String) -> Bool {
        let lower = word.lowercased()
        // Skip URLs, mentions, hashtags, likely IDs/paths, and very short tokens
        if lower.count < 2 { return false }
        if lower.hasPrefix("@") || lower.hasPrefix("#") || lower.contains("http") { return false }
        if lower.contains("/") || lower.contains("_") { return false }
        return true
    }
    
    private func shouldAutoCorrect(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.count < 2 { return false }
        if lower.hasPrefix("@") || lower.hasPrefix("#") || lower.contains("http") { return false }
        if lower.contains("/") || lower.contains("_") { return false }
        return true
    }
}

// MARK: - UndoManagerLite for autocorrect undo
final class UndoManagerLite {
    static let shared = UndoManagerLite()
    private var last: (original: String, corrected: String, correctedCount: Int)?
    
    private init() {}
    
    func record(original: String, corrected: String) {
        last = (original, corrected, corrected.count)
    }
    
    /// Undo the most recent auto- or tap-applied correction.
    /// Only performs if the current text suffix actually matches the corrected token,
    /// to avoid deleting user input typed after the correction.
    func tryUndo(in proxy: UITextDocumentProxy) -> Bool {
        guard let l = last else { return false }
        
        let before = proxy.documentContextBeforeInput ?? ""
        guard before.hasSuffix(l.corrected) else {
            // Not in a safe state to undo (user likely typed more) — skip.
            return false
        }
        
        for _ in 0..<l.correctedCount { proxy.deleteBackward() }
        proxy.insertText(l.original)
        
        // Mark as intentional so subsequent re-entries won't autocorrect
        LightweightSpellChecker.shared.recordIntentionalWord(l.original)
        
        last = nil
        return true
    }
}
