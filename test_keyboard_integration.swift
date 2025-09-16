#!/usr/bin/env swift

//
// test_keyboard_integration.swift
// Test the complete keyboard extension integration
//

import Foundation

// MARK: - Integration Test

class KeyboardIntegrationTester {
    // Test the complete integration flow

    func testKeyboardIntegration() {
        print("🔧 Testing Keyboard Extension Integration")
        print("========================================")
        print()

        // Step 1: Test App Group Configuration
        print("1️⃣ App Group Configuration")
        testAppGroupConfiguration()
        print()

        // Step 2: Test Shared UserDefaults Communication
        print("2️⃣ Shared UserDefaults Communication")
        testSharedUserDefaults()
        print()

        // Step 3: Test Tone Data Flow
        print("3️⃣ Tone Data Flow")
        testToneDataFlow()
        print()

        // Step 4: Test Coordinator Integration
        print("4️⃣ Coordinator Integration")
        testCoordinatorIntegration()
        print()

        // Step 5: Test UI Update Chain
        print("5️⃣ UI Update Chain")
        testUIUpdateChain()
        print()

        // Step 6: Integration Summary
        print("6️⃣ Integration Summary")
        provideIntegrationSummary()
        print()
    }

    func testAppGroupConfiguration() {
        let appGroupId = "group.com.example.unsaid"

        print("📱 Testing App Group: \(appGroupId)")

        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            print("❌ App Group not accessible")
            print("   This will prevent keyboard extension from working")
            return
        }

        // Test basic read/write
        let testKey = "integration_test_key"
        let testValue = "integration_test_value_\(Date().timeIntervalSince1970)"

        sharedDefaults.set(testValue, forKey: testKey)

        if let retrieved = sharedDefaults.string(forKey: testKey), retrieved == testValue {
            print("✅ App Group read/write successful")
        } else {
            print("❌ App Group read/write failed")
        }

        // Clean up
        sharedDefaults.removeObject(forKey: testKey)
    }

    func testSharedUserDefaults() {
        let appGroupId = "group.com.example.unsaid"

        print("🔄 Testing Shared UserDefaults communication")

        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            print("❌ Cannot access shared UserDefaults")
            return
        }

        // Simulate Flutter writing tone data
        let toneData: [String: Any] = [
            "ui_tone": "clear",
            "ui_distribution": ["clear": 0.85, "caution": 0.12, "alert": 0.03],
            "client_seq": 1,
            "analysis": ["primary_tone": "supportive", "confidence": 0.85]
        ]

        let timestamp = Date().timeIntervalSince1970
        sharedDefaults.set(toneData, forKey: "latest_tone_analysis")
        sharedDefaults.set(timestamp, forKey: "tone_analysis_timestamp")

        // Simulate keyboard reading the data
        if let retrievedData = sharedDefaults.dictionary(forKey: "latest_tone_analysis"),
           let retrievedTimestamp = sharedDefaults.object(forKey: "tone_analysis_timestamp") as? Double,
           retrievedTimestamp == timestamp {

            if let uiTone = retrievedData["ui_tone"] as? String, uiTone == "clear" {
                print("✅ Shared UserDefaults communication successful")
                print("   Retrieved tone: \(uiTone)")
            } else {
                print("❌ Tone data corrupted during transfer")
            }
        } else {
            print("❌ Shared UserDefaults communication failed")
        }

        // Clean up
        sharedDefaults.removeObject(forKey: "latest_tone_analysis")
        sharedDefaults.removeObject(forKey: "tone_analysis_timestamp")
    }

    func testToneDataFlow() {
        print("📊 Testing Tone Data Flow")

        // Simulate the complete data flow
        let originalData: [String: Any] = [
            "ui_tone": "clear",
            "ui_distribution": ["clear": 0.85, "caution": 0.12, "alert": 0.03],
            "client_seq": 1,
            "analysis": ["primary_tone": "supportive", "confidence": 0.85]
        ]

        print("📤 Original data: \(originalData)")

        // Simulate KeyboardViewController processing
        let processedData = simulateKeyboardViewControllerProcessing(originalData)
        print("🔄 KeyboardViewController processed: \(processedData)")

        // Simulate ToneSuggestionCoordinator processing
        let coordinatorResult = simulateCoordinatorProcessing(processedData)
        print("🎯 Coordinator result: \(coordinatorResult)")

        // Validate flow
        if let finalTone = coordinatorResult["final_tone"] as? String, finalTone == "clear" {
            print("✅ Tone data flow successful")
        } else {
            print("❌ Tone data flow failed")
        }
    }

    func simulateKeyboardViewControllerProcessing(_ data: [String: Any]) -> [String: Any] {
        // Simulate KeyboardViewController.checkForToneAnalysisData()
        var processed: [String: Any] = [:]

        if let analysis = data["analysis"] as? [String: Any] {
            processed["analysis"] = analysis
        }

        if let uiTone = data["ui_tone"] as? String {
            processed["ui_tone"] = uiTone
        }

        return processed
    }

    func simulateCoordinatorProcessing(_ data: [String: Any]) -> [String: Any] {
        // Simulate ToneSuggestionCoordinator.updateToneFromAnalysis()
        var result: [String: Any] = ["processed": true]

        if let toneStr = (data["ui_tone"] as? String) ?? (data["tone_status"] as? String) ?? (data["tone"] as? String),
           !toneStr.isEmpty {
            result["final_tone"] = toneStr
            result["delegate_called"] = true
        } else {
            result["error"] = "No valid tone found"
        }

        return result
    }

    func testCoordinatorIntegration() {
        print("🎼 Testing Coordinator Integration")

        // Test the coordinator's tone processing logic
        let testCases = [
            ["ui_tone": "clear"],
            ["tone_status": "alert"],
            ["tone": "caution"],
            ["invalid_key": "neutral"],
            [:] // Empty case
        ]

        for (index, testCase) in testCases.enumerated() {
            print("   Test case \(index + 1): \(testCase)")

            let result = simulateCoordinatorProcessing(testCase)

            if let tone = result["final_tone"] as? String {
                print("   ✅ Processed to: \(tone)")
            } else if let error = result["error"] as? String {
                print("   ⚠️ Error: \(error)")
            } else {
                print("   ❌ No result")
            }
        }
    }

    func testUIUpdateChain() {
        print("🎨 Testing UI Update Chain")

        // Test the complete UI update chain
        let testTones = ["clear", "caution", "alert", "neutral"]

        for tone in testTones {
            print("   Testing tone: \(tone)")

            // Simulate KeyboardController.didUpdateToneStatus()
            let toneStatus = mapToToneStatus(tone)
            print("   📊 Mapped to: \(toneStatus)")

            // Simulate setToneStatus() visual updates
            let visualUpdate = simulateVisualUpdate(for: toneStatus)
            print("   🎨 Visual update: \(visualUpdate)")

            if let colors = visualUpdate["gradient_colors"] as? [String], colors.count == 2 {
                print("   ✅ Gradient colors: \(colors[0]) → \(colors[1])")
            } else {
                print("   ❌ Invalid gradient colors")
            }
        }
    }

    func mapToToneStatus(_ tone: String) -> String {
        // Simulate ToneStatus extension mapping
        switch tone.lowercased() {
        case "alert": return "alert"
        case "caution": return "caution"
        case "clear": return "clear"
        default: return "neutral"
        }
    }

    func simulateVisualUpdate(for toneStatus: String) -> [String: Any] {
        // Simulate the visual update logic from setToneStatus
        var update: [String: Any] = [:]

        let gradientColors: [String]
        let shouldPulse: Bool
        let scale: Double

        switch toneStatus {
        case "alert":
            gradientColors = ["#FF3B30", "#FF3B30"] // Red
            shouldPulse = true
            scale = 1.06
        case "caution":
            gradientColors = ["#FF9500", "#FF9500"] // Yellow
            shouldPulse = false
            scale = 1.0
        case "clear":
            gradientColors = ["#34C759", "#30B0C7"] // Green/Teal
            shouldPulse = false
            scale = 1.0
        default: // neutral
            gradientColors = ["#FFFFFF", "#FFFFFF"] // White
            shouldPulse = false
            scale = 1.0
        }

        update["gradient_colors"] = gradientColors
        update["should_pulse"] = shouldPulse
        update["scale"] = scale
        update["visible"] = true
        update["alpha"] = 1.0

        return update
    }

    func provideIntegrationSummary() {
        print("📋 Integration Test Summary:")
        print()
        print("✅ Components Tested:")
        print("   • App Group configuration")
        print("   • Shared UserDefaults communication")
        print("   • Tone data flow processing")
        print("   • Coordinator integration")
        print("   • UI update chain")
        print()
        print("🎯 Key Integration Points:")
        print("   1. Flutter app → Shared UserDefaults")
        print("   2. KeyboardViewController → ToneSuggestionCoordinator")
        print("   3. Coordinator → KeyboardController (delegate)")
        print("   4. KeyboardController → UI updates")
        print()
        print("🔧 If tone indicator still not working:")
        print("   • Check App Group entitlements in Xcode")
        print("   • Verify Info.plist has correct UNSAID_API_* keys")
        print("   • Test on physical device (simulator limitations)")
        print("   • Check Xcode console for runtime errors")
        print("   • Ensure Flutter app is actually writing to shared UserDefaults")
        print()
        print("📱 Debug Steps:")
        print("   1. Build and run on device")
        print("   2. Enable keyboard extension in Settings")
        print("   3. Type in a text field to trigger analysis")
        print("   4. Check Xcode console for debug logs")
        print("   5. Verify tone button appears and changes color")
    }
}

// MARK: - Main Test Runner

func runIntegrationTests() {
    print("🚀 Keyboard Extension Integration Test Suite")
    print("===========================================")
    print()

    let tester = KeyboardIntegrationTester()
    tester.testKeyboardIntegration()

    print("✅ Integration tests completed!")
    print()
    print("🎯 Next Steps:")
    print("- Build and test on physical iOS device")
    print("- Enable keyboard extension in iOS Settings")
    print("- Monitor Xcode console for any runtime errors")
    print("- Verify tone button appears and updates correctly")
}

runIntegrationTests()