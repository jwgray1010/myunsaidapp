//
//  CommunicationPatternLearner.swift
//  UnsaidKeyboard
//
//  Lightweight, in-process rollup that reads SafeKeyboardDataStorage,
//  computes 7-day attachment signals, and updates PersonalityDataBridge.
//

import Foundation

@available(iOS 13.0, *)
final class CommunicationPatternLearner {

    struct Rollup {
        let primary: String
        let scores: [String: Double]
        let confidence: Double   // 0..1
        let samples: Int
        let windowComplete: Bool
        let daysObserved: Int
    }

    private struct Weights {
        let catAnxious: Double = 0.6
        let catAvoidant: Double = 0.6
        let catDisorganized: Double = 0.6
        let uiClearToSecure: Double = 0.30
        let uiAlertToAnxious: Double = 0.20
        let acceptBoostSecure: Double = 0.40
        let commPursueAnxious: Double = 0.20
        let commWithdrawAvoidant: Double = 0.25
    }

    private let w = Weights()
    private let minConfirmConfidence: Double = 0.66
    private let minConfirmSamples: Int = 12 // ← require enough evidence

    private let bridge: PersonalityDataBridge
    private let storage = SafeKeyboardDataStorage.shared
    private let windowDays: Int

    init(bridge: PersonalityDataBridge, windowDays: Int = 7) {
        self.bridge = bridge
        self.windowDays = windowDays
    }

    func learnNow() async -> Rollup {
        let buckets = storage.getAllPendingData()
        let tones = (buckets["tone_data"] ?? [])
        let interactions = (buckets["interactions"] ?? [])

        let cutoff = Date().timeIntervalSince1970 - Double(windowDays) * 86_400.0
        let recentTones = tones.compactMap { $0["ts"] as? Double }.enumerated().compactMap { idx, ts in
            ts >= cutoff ? tones[idx] : nil
        }
        let recentInteractions = interactions.compactMap { $0["ts"] as? Double }.enumerated().compactMap { idx, ts in
            ts >= cutoff ? interactions[idx] : nil
        }

        var score: [String: Double] = ["secure": 0, "anxious": 0, "avoidant": 0, "disorganized": 0]

        // --- Tone signals
        for t in recentTones {
            let ui = (t["tone"] as? String ?? "neutral").lowercased()
            let conf = max(0, min(1, (t["cf"] as? Double) ?? 0.5))
            let rawCats = (t["cat"] as? [String]) ?? []
            // lowercase tokens once
            let cats = Set(rawCats.map { $0.lowercased() })

            if cats.contains(where: { $0.contains("reassurance") || $0.contains("connection") }) {
                score["anxious", default: 0] += w.catAnxious * conf
            }
            if cats.contains(where: { $0.contains("withdrawal") || $0.contains("distancing") }) {
                score["avoidant", default: 0] += w.catAvoidant * conf
            }
            if cats.contains(where: { $0.contains("mixed_signals") }) {
                score["disorganized", default: 0] += w.catDisorganized * conf
            }
            if ui == "clear"  { score["secure",  default: 0] += w.uiClearToSecure  * conf }
            if ui == "alert"  { score["anxious", default: 0] += w.uiAlertToAnxious * conf }
        }

        // --- Interaction signals
        for i in recentInteractions {
            let accepted = (i["acc"] as? Bool) ?? false
            let itype = ((i["itype"] as? String) ?? "").lowercased()
            let comm  = ((i["cpat"]  as? String) ?? "").lowercased()
            let rel   = ((i["rctx"]  as? String) ?? "").lowercased()

            if accepted { score["secure", default: 0] += w.acceptBoostSecure }
            if comm.contains("pursue") || rel.contains("strained") { score["anxious", default: 0]  += w.commPursueAnxious }
            if comm.contains("withdraw") || itype.contains("silence") { score["avoidant", default: 0] += w.commWithdrawAvoidant }
        }

        // --- Normalize (safe)
        let clamped = score.mapValues { max(0, $0) }
        var total = clamped.values.reduce(0, +)
        if total <= 0 { total = 1 } // avoid div-by-zero, yields all zeros -> secure=0
        var normalized = clamped.mapValues { $0 / total }

        // ensure numeric stability
        normalized = normalized.mapValues { v in
            let x = v.isFinite ? v : 0
            return min(1, max(0, x))
        }
        // renormalize to sum=1
        let sum = normalized.values.reduce(0, +)
        if sum > 0 { normalized = normalized.mapValues { $0 / sum } }

        let primary = normalized.max(by: { $0.value < $1.value })?.key ?? "secure"
        let sorted = normalized.values.sorted(by: >)
        let margin = (sorted.first ?? 0) - (sorted.dropFirst().first ?? 0)

        let samples = recentTones.count + recentInteractions.count
        let confidence = min(1.0, max(0.0, margin * 0.9) * log(Double(samples) + 1.0))

        // --- Update bridge respecting learning window & thresholds
        await bridge.markAttachmentLearningStartedIfNeeded(days: windowDays)
        await bridge.setLearnerAttachmentStyle(primary, confidence: confidence, source: "local")

        let windowComplete = await bridge.isLearningWindowComplete()
        if windowComplete && confidence >= minConfirmConfidence && samples >= minConfirmSamples {
            await bridge.markAttachmentConfirmed(style: primary, source: "local_learner")
        }

        // analytics (optional)
        SafeKeyboardDataStorage.shared.recordAnalytics(
            event: "attachment_rollup",
            data: ["primary": primary,
                   "confidence": String(format: "%.2f", confidence),
                   "samples": "\(samples)"]
        )

        // Distinct days observed (more truthful than samples/8 heuristic)
        let allTs = (recentTones.map { $0["ts"] as? Double ?? 0 } + recentInteractions.map { $0["ts"] as? Double ?? 0 })
        let distinctDays = Set(allTs.map { Int($0 / 86_400.0) }).count

        return Rollup(primary: primary,
                      scores: normalized,
                      confidence: confidence,
                      samples: samples,
                      windowComplete: windowComplete,
                      daysObserved: min(windowDays, max(0, distinctDays)))
    }
}