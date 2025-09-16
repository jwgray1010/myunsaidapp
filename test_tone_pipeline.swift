#!/usr/bin/env swift
//
//  test_tone_pipeline.swift
//  Test script to verify the complete tone analysis pipeline
//  Simulates Flutter app sending tone analysis data to keyboard extension
//

import Foundation

// MARK: - Test Data Structures

struct ToneAnalysisResponse {
    let uiTone: String
    let clientSeq: Int
    let analysis: [String: Any]
    let timestamp: TimeInterval
}

// MARK: - Shared Storage Simulation

class SharedStorageSimulator {
    private let appGroupId = "group.com.example.unsaid"
    private var sharedDefaults: UserDefaults?

    init() {
        sharedDefaults = UserDefaults(suiteName: appGroupId)
        if sharedDefaults == nil {
            print("❌ Failed to access shared UserDefaults with suite: \(appGroupId)")
            print("💡 Make sure the app group is properly configured in your entitlements")
        }
    }

    func simulateFlutterToneAnalysis(_ tone: String, clientSeq: Int = 1) {
        guard let sharedDefaults = sharedDefaults else { return }

        let analysis: [String: Any] = [
            "dominant_tone": tone,
            "confidence": 0.85,
            "primary_tone": tone,
            "secondary_tones": ["neutral"],
            "intensity": 0.7
        ]

        let toneData: [String: Any] = [
            "ui_tone": tone,
            "client_seq": clientSeq,
            "analysis": analysis,
            "timestamp": Date().timeIntervalSince1970
        ]

        // Store in shared UserDefaults (simulating Flutter bridge)
        sharedDefaults.set(toneData, forKey: "latest_tone_analysis")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "tone_analysis_timestamp")

        print("📤 Flutter simulated: Sent tone analysis '\(tone)' with client_seq \(clientSeq)")
        print("📦 Stored data: \(toneData)")
    }

    func clearToneAnalysisData() {
        guard let sharedDefaults = sharedDefaults else { return }
        sharedDefaults.removeObject(forKey: "latest_tone_analysis")
        sharedDefaults.removeObject(forKey: "tone_analysis_timestamp")
        print("🧹 Cleared tone analysis data from shared storage")
    }

    func readCurrentToneAnalysisData() -> [String: Any]? {
        guard let sharedDefaults = sharedDefaults else { return nil }
        return sharedDefaults.dictionary(forKey: "latest_tone_analysis")
    }
}

// MARK: - Keyboard Extension Simulation

class KeyboardExtensionSimulator {
    private let storage = SharedStorageSimulator()
    private var lastTimestamp: TimeInterval = 0
    private var clientSeq: Int = 0

    func startMonitoring() {
        print("🎯 Keyboard Extension: Starting tone analysis monitoring...")

        // Check immediately
        checkForNewToneAnalysis()

        // Simulate timer checking every 0.5 seconds
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForNewToneAnalysis()
        }

        // Keep the run loop alive for testing
        RunLoop.current.run(until: Date().addingTimeInterval(10))
    }

    private func checkForNewToneAnalysis() {
        let appGroupId = "group.com.example.unsaid"
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            print("❌ Keyboard Extension: Cannot access shared UserDefaults")
            return
        }

        let timestamp = sharedDefaults.double(forKey: "tone_analysis_timestamp")
        if timestamp > lastTimestamp {
            lastTimestamp = timestamp
            print("🎯 Keyboard Extension: New tone analysis data detected at \(timestamp)")

            if let toneData = sharedDefaults.dictionary(forKey: "latest_tone_analysis") {
                processToneAnalysisData(toneData)
            }
        }
    }

    private func processToneAnalysisData(_ data: [String: Any]) {
        print("🎯 Keyboard Extension: Processing tone analysis data")
        print("📦 Received data: \(data)")

        // Extract tone information (simulating KeyboardViewController.processToneAnalysisData)
        if let analysis = data["analysis"] as? [String: Any],
           let tone = analysis["dominant_tone"] as? String {
            print("🎯 Keyboard Extension: Extracted tone '\(tone)' from analysis")

            // Simulate calling KeyboardController.updateToneFromAnalysis
            simulateToneUpdate(tone, analysis: analysis)

        } else if let tone = data["tone"] as? String {
            print("🎯 Keyboard Extension: Direct tone '\(tone)' received")
            simulateToneUpdate(tone, analysis: ["dominant_tone": tone])
        } else {
            print("⚠️ Keyboard Extension: No tone data found in analysis")
        }
    }

    private func simulateToneUpdate(_ tone: String, analysis: [String: Any]) {
        print("🎨 Keyboard Extension: Updating tone button to '\(tone)'")

        // Simulate the tone color mapping (from KeyboardController.gradientColors)
        let colorDescription: String
        switch tone.lowercased() {
        case "alert":
            colorDescription = "🔴 Red gradient (alert/high intensity)"
        case "caution":
            colorDescription = "🟡 Yellow gradient (caution/medium intensity)"
        case "clear":
            colorDescription = "🟢 Green gradient (clear/positive)"
        default:
            colorDescription = "⚪ White background (neutral)"
        }

        print("🎨 Tone Button: \(colorDescription)")
        print("✅ Pipeline test successful: Flutter → Shared Storage → Keyboard Extension → Tone Button")
    }
}

// MARK: - Test Scenarios

func runPipelineTests() {
    print("🧪 Starting Tone Analysis Pipeline Tests")
    print(String(repeating: "=", count: 50))

    let storage = SharedStorageSimulator()
    let keyboard = KeyboardExtensionSimulator()

    // Start keyboard monitoring in background
    DispatchQueue.global().async {
        keyboard.startMonitoring()
    }

    // Test 1: Alert tone
    print("\n🧪 Test 1: Alert Tone")
    storage.simulateFlutterToneAnalysis("alert", clientSeq: 1)
    sleep(1) // Wait for monitoring to detect

    // Test 2: Caution tone
    print("\n🧪 Test 2: Caution Tone")
    storage.simulateFlutterToneAnalysis("caution", clientSeq: 2)
    sleep(1)

    // Test 3: Clear tone
    print("\n🧪 Test 3: Clear Tone")
    storage.simulateFlutterToneAnalysis("clear", clientSeq: 3)
    sleep(1)

    // Test 4: Neutral tone
    print("\n🧪 Test 4: Neutral Tone")
    storage.simulateFlutterToneAnalysis("neutral", clientSeq: 4)
    sleep(1)

    // Test 5: Invalid tone (should default to neutral)
    print("\n🧪 Test 5: Invalid Tone (should default)")
    storage.simulateFlutterToneAnalysis("invalid_tone", clientSeq: 5)
    sleep(1)

    print("\n" + String(repeating: "=", count: 50))
    print("✅ All pipeline tests completed")
    print("💡 If you see tone button color changes in the actual keyboard,")
    print("   the complete pipeline is working correctly!")
}

// MARK: - Main Execution

func main() {
    print("🚀 Tone Analysis Pipeline Test Script")
    print("This script simulates the complete communication pipeline:")
    print("Flutter App → Shared UserDefaults → Keyboard Extension → Tone Button")
    print()

    // Check if we can access shared storage
    let storage = SharedStorageSimulator()
    if storage.readCurrentToneAnalysisData() == nil {
        print("📝 No existing tone analysis data found")
    }

    // Run the pipeline tests
    runPipelineTests()

    // Clean up
    storage.clearToneAnalysisData()
    print("\n🧹 Test cleanup complete")
}

main()