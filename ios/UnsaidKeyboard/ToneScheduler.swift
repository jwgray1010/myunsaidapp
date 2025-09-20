//
//  ToneScheduler.swift
//  UnsaidKeyboard
//
//  Full-text document-level tone analysis scheduler
//  Replaces sentence-based analysis with debounced full-document approach
//

import Foundation
import CryptoKit

/// Handles debounced full-text tone analysis with document-level consistency
final class ToneScheduler {
    
    // MARK: - Configuration
    private let debounceInterval: TimeInterval = 0.4 // 400ms
    private let coordinator: ToneSuggestionCoordinator
    
    // MARK: - State
    private var currentDocSeq: Int = 0
    private var lastTextHash: String = ""
    private var debounceTask: Task<Void, Never>?
    private var isAnalysisInFlight = false
    
    // MARK: - Initialization
    init(coordinator: ToneSuggestionCoordinator) {
        self.coordinator = coordinator
    }
    
    // MARK: - Public Interface
    
    /// Schedule full-text analysis with debouncing
    /// - Parameters:
    ///   - fullText: Complete text content to analyze
    ///   - triggerReason: Why analysis was triggered (idle, punctuation, etc.)
    func schedule(fullText: String, triggerReason: String = "idle") {
        // Cancel previous debounce
        debounceTask?.cancel()
        
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textHash = sha256(trimmed)
        
        // Skip if text is empty or unchanged
        guard !trimmed.isEmpty, textHash != lastTextHash else {
            print("📄 ToneScheduler: Skipping analysis - empty or unchanged text")
            return
        }
        
        // Skip if text is too short (client-side gate matching server)
        guard shouldAnalyzeText(trimmed) else {
            print("📄 ToneScheduler: Skipping analysis - text too short (\(trimmed.count) chars)")
            return
        }
        
        print("📄 ToneScheduler: Scheduling analysis for \(trimmed.count) chars, trigger: \(triggerReason)")
        
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.debounceInterval ?? 0.4 * 1_000_000_000))
                await self?.performAnalysis(fullText: trimmed, textHash: textHash)
            } catch {
                // Task cancelled (normal for debouncing)
            }
        }
    }
    
    /// Immediately trigger analysis (for urgent cases like punctuation)
    func scheduleImmediate(fullText: String, triggerReason: String = "urgent") {
        debounceTask?.cancel()
        
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let textHash = sha256(trimmed)
        
        guard !trimmed.isEmpty, textHash != lastTextHash else { return }
        guard shouldAnalyzeText(trimmed) else { return }
        
        print("📄 ToneScheduler: Immediate analysis for \(trimmed.count) chars, trigger: \(triggerReason)")
        
        Task { [weak self] in
            await self?.performAnalysis(fullText: trimmed, textHash: textHash)
        }
    }
    
    // MARK: - Private Implementation
    
    private func shouldAnalyzeText(_ text: String) -> Bool {
        // Match server-side gating: <4 chars or <2 words
        guard text.count >= 4 else { return false }
        
        let words = text.split(separator: " ").filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }
        
        return true
    }
    
    private func performAnalysis(fullText: String, textHash: String) async {
        guard !isAnalysisInFlight else {
            print("📄 ToneScheduler: Analysis already in flight, skipping")
            return
        }
        
        isAnalysisInFlight = true
        currentDocSeq += 1
        lastTextHash = textHash
        
        let docSeq = currentDocSeq
        let startTime = Date()
        
        print("📄 ToneScheduler: Starting analysis - docSeq: \(docSeq), hash: \(textHash.prefix(8)), length: \(fullText.count)")
        
        let payload: [String: Any] = [
            "mode": "full",
            "text": fullText,
            "context": "general",
            "doc_seq": docSeq,
            "text_hash": textHash
        ]
        
        // Use coordinator's networking
        await MainActor.run {
            coordinator.postFullDocumentTone(payload: payload) { [weak self] response in
                self?.handleAnalysisResponse(response, expectedDocSeq: docSeq, expectedHash: textHash, startTime: startTime)
            }
        }
    }
    
    private func handleAnalysisResponse(_ response: [String: Any]?, expectedDocSeq: Int, expectedHash: String, startTime: Date) {
        defer { isAnalysisInFlight = false }
        
        let duration = Date().timeIntervalSince(startTime)
        
        guard let response = response else {
            print("📄 ToneScheduler: Analysis failed - no response")
            return
        }
        
        // Validate response matches current state
        let responseDocSeq = response["doc_seq"] as? Int ?? -1
        let responseHash = response["text_hash"] as? String ?? ""
        
        guard responseDocSeq == expectedDocSeq else {
            print("📄 ToneScheduler: Dropping stale response - docSeq mismatch (\(responseDocSeq) != \(expectedDocSeq))")
            return
        }
        
        guard responseHash == expectedHash else {
            print("📄 ToneScheduler: Dropping stale response - hash mismatch")
            return
        }
        
        // Extract document tone from ui_distribution (not buckets)
        let uiTone = response["ui_tone"] as? String ?? "clear"
        let uiDistribution = response["ui_distribution"] as? [String: Double] ?? ["clear": 1.0, "caution": 0.0, "alert": 0.0]
        let confidence = response["confidence"] as? Double ?? 0.0
        
        print("📄 ToneScheduler: Analysis complete - docSeq: \(expectedDocSeq), ui_tone: \(uiTone), duration: \(Int(duration * 1000))ms")
        print("📄 ToneScheduler: UI Distribution - clear: \(String(format: "%.2f", uiDistribution["clear"] ?? 0)), caution: \(String(format: "%.2f", uiDistribution["caution"] ?? 0)), alert: \(String(format: "%.2f", uiDistribution["alert"] ?? 0))")
        
        // Apply document tone to UI
        coordinator.applyDocumentTone(uiTone: uiTone, uiDistribution: uiDistribution, confidence: confidence)
    }
    
    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Extensions for trigger detection
extension ToneScheduler {
    
    /// Check if text ends with punctuation that should trigger immediate analysis
    func shouldTriggerImmediate(for text: String) -> Bool {
        let punctuation: Set<Character> = [".", "!", "?", "\n"]
        return text.last.map(punctuation.contains) ?? false
    }
}