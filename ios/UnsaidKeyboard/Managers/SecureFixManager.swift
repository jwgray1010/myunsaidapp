//
//  SecureFixManager.swift
//  UnsaidKeyboard
//
//  Manages SecureFix gating (tone->advice prerequisite), daily usage limits, and tone/personality-aware rewrites
//

import Foundation
import UIKit
import os.log

@MainActor
protocol SecureFixManagerDelegate: AnyObject {
    func getOpenAIAPIKey() -> String
    func getCurrentTextForAnalysis() -> String
    func replaceCurrentMessage(with newText: String)
    func buildUserProfileForSecureFix() -> [String: Any]
    func showUsageLimitAlert(message: String)
}

enum SecureTone: String {
    case neutral, alert, caution, clear
}

@MainActor
final class SecureFixManager {

    weak var delegate: SecureFixManagerDelegate?

    // MARK: - Logging
    private let logger = Logger(subsystem: "com.example.unsaid.UnsaidKeyboard", category: "SecureFixManager")

    // MARK: - Config
    private let maxDailySecureFixUses = 5  // Reduced from 10 to 5 for cost control
    private let secureFixUsageKey = "SecureFixDailyUsage"
    private let secureFixDayKey = "SecureFixUsageDay" // yyyyMMdd as Int
    private let sharedDefaults = AppGroups.shared

    // Require: Tone Analysis pressed + Advice visible before SecureFix can run
    private var adviceGateSatisfied = false
    private var lastTone: SecureTone = .neutral

    // Optional: allow model injection
    private let modelName: String

    // MARK: - Storage handled via sharedDefaults (already a UserDefaults)

    init(modelName: String = "gpt-4o-mini") {
        self.modelName = modelName
    }

    // MARK: - Public API (called by your keyboard controller)

    /// Call this when you actually surface an advice chip (after Tone Analysis succeeds).
    func markAdviceShown(toneString: String?) {
        adviceGateSatisfied = true
        if let s = toneString?.lowercased() {
            switch s {
            case "alert", "angry", "harsh", "aggressive": lastTone = .alert
            case "caution", "warning", "passive aggressive", "passive-aggressive": lastTone = .caution
            case "clear", "positive", "supportive", "kind": lastTone = .clear
            default: lastTone = .neutral
            }
        } else {
            lastTone = .neutral
        }
    }

    /// Optionally reset gate when advice chip is dismissed or new compose starts.
    func resetAdviceGate() {
        adviceGateSatisfied = false
        lastTone = .neutral
    }
    
    func hasAdviceBeenShown() -> Bool {
        return adviceGateSatisfied
    }

    func canUseSecureFix() -> Bool {
        let defaults = sharedDefaults
        let (todayKey, storedKey) = (currentDayKey(), defaults.integer(forKey: secureFixDayKey))
        var usage = defaults.integer(forKey: secureFixUsageKey)

        if storedKey != todayKey {
            // New day, reset
            defaults.set(todayKey, forKey: secureFixDayKey)
            defaults.set(0, forKey: secureFixUsageKey)
            usage = 0
        }
        return usage < maxDailySecureFixUses
    }

    func getRemainingSecureFixUses() -> Int {
        let defaults = sharedDefaults
        let (todayKey, storedKey) = (currentDayKey(), defaults.integer(forKey: secureFixDayKey))
        let usage = (storedKey == todayKey) ? defaults.integer(forKey: secureFixUsageKey) : 0
        return max(0, maxDailySecureFixUses - usage)
    }

    /// Main entry point for your SecureFix button.
    /// Enforces: (1) adviceGateSatisfied, (2) daily limit, (3) non-empty text.
    func handleSecureFix() {
        guard adviceGateSatisfied else {
            delegate?.showUsageLimitAlert(message: "Run Tone Analysis first. After advice appears, you can use Secure Fix.")
            return
        }

        guard canUseSecureFix() else {
            let remaining = getRemainingSecureFixUses()
            let msg = remaining > 0
                ? "You have \(remaining) Secure Fix uses remaining today."
                : "You’ve reached your daily limit of \(maxDailySecureFixUses) Secure Fix uses. Try again tomorrow."
            delegate?.showUsageLimitAlert(message: msg)
            return
        }

        let currentText = delegate?.getCurrentTextForAnalysis().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !currentText.isEmpty else {
            delegate?.showUsageLimitAlert(message: "Type a message first, then tap Secure Fix.")
            return
        }

        incrementSecureFixUsage()

        // Perform network off the main thread; deliver result back on main.
        Task {
            let improved = await callOpenAIRewrite(text: currentText, tone: lastTone)
            if let improvedText = improved, !improvedText.isEmpty {
                delegate?.replaceCurrentMessage(with: improvedText)
            } else {
                delegate?.showUsageLimitAlert(message: "Couldn’t create a secure rewrite. Please try again.")
            }
        }
    }

    // MARK: - Usage accounting

    private func incrementSecureFixUsage() {
        let defaults = sharedDefaults
        let todayKey = currentDayKey()
        let storedKey = defaults.integer(forKey: secureFixDayKey)
        var usage = defaults.integer(forKey: secureFixUsageKey)

        if storedKey != todayKey {
            defaults.set(todayKey, forKey: secureFixDayKey)
            usage = 0
        }
        usage += 1
        defaults.set(usage, forKey: secureFixUsageKey)
        logger.info("SecureFix used: \(usage)/\(self.maxDailySecureFixUses) today")
    }

    private func currentDayKey() -> Int {
        // Local midnight reset using user's current calendar/timezone
        var cal = Calendar.current
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let y = (comps.year ?? 0), m = (comps.month ?? 0), d = (comps.day ?? 0)
        return y * 10_000 + m * 100 + d // yyyyMMdd as Int
    }

    // MARK: - OpenAI call

    private func callOpenAIRewrite(text: String, tone: SecureTone) async -> String? {
        guard let apiKey = delegate?.getOpenAIAPIKey(), !apiKey.isEmpty else {
            logger.error("OpenAI API key missing")
            return nil
        }

        // Build personality context
        let profile = delegate?.buildUserProfileForSecureFix() ?? [:]
        let personalityBrief = compactJSONString(profile) ?? ""

        // Strong, deterministic guardrails for “secure communicator” rewrites
        let systemPrompt =
        """
        You are SecureFix, a tone- and attachment-aware rewrite assistant.
        Goal: produce a SINGLE, concise rewrite of the user's message that models a SECURE communicator.
        Requirements:
        - Preserve the user’s intent; remove blame, threats, and harshness.
        - Prefer “I” statements, specificity, ownership, and clear requests/boundaries.
        - Calibrate to the given tone and personality traits.
        - Keep it brief (1–2 sentences). No explanations, no quotes, no headings. Return ONLY the rewritten text.

        Context:
        - Personality: \(personalityBrief)
        - Detected tone: \(tone.rawValue)
        """

        let payload: [String: Any] = [
            "model": modelName,              // keep your prod model here
            "temperature": 0.2,
            "max_tokens": 180,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            logger.error("Failed to encode JSON payload")
            return nil
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 20

        // Ephemeral session: safer for extensions
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("OpenAI HTTP error: \(code)")
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any],
                var content = message["content"] as? String
            else {
                logger.error("Unexpected OpenAI response structure")
                return nil
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        } catch {
            logger.error("OpenAI request failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Utils

    private func compactJSONString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: d, encoding: .utf8)
        else { return nil }
        return s
    }
}
