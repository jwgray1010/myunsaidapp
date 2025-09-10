//
//  PersonalityDataPlugin.swift
//  Runner
//
//  Flutter plugin bridge that connects to PersonalityDataBridge in UnsaidKeyboard target
//

import UIKit
import Flutter

@objc public class PersonalityDataPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.unsaid/personality_data", binaryMessenger: registrar.messenger())
    let instance = PersonalityDataPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Use centralized App Group configuration
    let suite = AppGroups.defaults
    
    switch call.method {
    case "storePersonalityData":
      guard let dict = call.arguments as? [String: Any] else { return result(false) }
      // Store as JSON to handle complex types
      if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
         let jsonString = String(data: jsonData, encoding: .utf8) {
        suite.set(jsonString, forKey: "personality_data_json")
        suite.set(dict["attachment_style"] as? String ?? "secure", forKey: "attachment_style")
        suite.set(dict["communication_style"] as? String ?? "direct", forKey: "communication_style")
        suite.set(dict["personality_type"] as? String ?? "analytical", forKey: "personality_type")
        suite.set(dict["is_complete"] as? Bool ?? false, forKey: "personality_test_complete")
        suite.set(Date(), forKey: "personality_last_update")
      }
      result(true)

    case "getPersonalityData":
      let jsonString = suite.string(forKey: "personality_data_json") ?? "{}"
      if let jsonData = jsonString.data(using: .utf8),
         let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
        result(dict)
      } else {
        // Fallback to individual keys
        let fallback: [String: Any] = [
          "attachment_style": suite.string(forKey: "attachment_style") ?? "secure",
          "communication_style": suite.string(forKey: "communication_style") ?? "direct",
          "personality_type": suite.string(forKey: "personality_type") ?? "analytical",
          "is_complete": suite.bool(forKey: "personality_test_complete")
        ]
        result(fallback)
      }

    case "isPersonalityTestComplete":
      result(suite.bool(forKey: "personality_test_complete"))

    case "clearPersonalityData":
      let keys = ["personality_data_json", "attachment_style", "communication_style", 
                  "personality_type", "personality_test_complete", "personality_last_update",
                  "currentEmotionalState", "currentEmotionalStateBucket"]
      for key in keys {
        suite.removeObject(forKey: key)
      }
      result(true)

    case "debugPersonalityData", "debugPrintPersonalityData":
      let jsonString = suite.string(forKey: "personality_data_json") ?? "{}"
      print("🧪 Personality Data: \(jsonString)")
      result(true)

    case "setTestPersonalityData":
      let demo: [String: Any] = [
        "attachment_style": "secure",
        "communication_style": "assertive", 
        "personality_type": "B",
        "scores": ["A": 42, "B": 88, "C": 30, "D": 15],
        "is_complete": true
      ]
      if let jsonData = try? JSONSerialization.data(withJSONObject: demo),
         let jsonString = String(data: jsonData, encoding: .utf8) {
        suite.set(jsonString, forKey: "personality_data_json")
        suite.set("secure", forKey: "attachment_style")
        suite.set("assertive", forKey: "communication_style")
        suite.set("B", forKey: "personality_type")
        suite.set(true, forKey: "personality_test_complete")
      }
      result(true)

    case "storePersonalityTestResults", "storePersonalityComponents":
      if let dict = call.arguments as? [String: Any],
         let jsonData = try? JSONSerialization.data(withJSONObject: dict),
         let jsonString = String(data: jsonData, encoding: .utf8) {
        suite.set(jsonString, forKey: "personality_test_results")
        result(true)
      } else { result(false) }

    case "getPersonalityTestResults":
      let jsonString = suite.string(forKey: "personality_test_results") ?? "{}"
      if let jsonData = jsonString.data(using: .utf8),
         let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
        result(dict)
      } else {
        result([:])
      }

    case "getDominantPersonalityType":
      result(suite.string(forKey: "personality_type") ?? "B")

    case "getPersonalityTypeLabel":
      let type = suite.string(forKey: "personality_type") ?? "B"
      let label = type == "A" ? "Anxious Attachment" :
                  type == "B" ? "Secure Attachment" :
                  type == "C" ? "Dismissive Avoidant" :
                  type == "D" ? "Disorganized/Fearful Avoidant" : "Secure Attachment"
      result(label)

    case "getPersonalityScores":
      let jsonString = suite.string(forKey: "personality_data_json") ?? "{}"
      if let jsonData = jsonString.data(using: .utf8),
         let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
         let scores = dict["scores"] as? [String: Int] {
        result(scores)
      } else {
        result([:])
      }

    case "setUserEmotionalState":
      if let dict = call.arguments as? [String: Any] {
        suite.set(dict["state"] as? String ?? "neutral_distracted", forKey: "currentEmotionalState")
        suite.set(dict["bucket"] as? String ?? "moderate", forKey: "currentEmotionalStateBucket")
        suite.set(dict["label"] as? String ?? "Neutral / Distracted", forKey: "emotionalStateLabel")
        result(true)
      } else { result(false) }

    case "getUserEmotionalState":
      result(suite.string(forKey: "currentEmotionalState") ?? "neutral_distracted")

    case "getUserEmotionalBucket":
      result(suite.string(forKey: "currentEmotionalStateBucket") ?? "moderate")

    case "generatePersonalityContext":
      let type = suite.string(forKey: "personality_type") ?? "B"
      let attachment = suite.string(forKey: "attachment_style") ?? "secure"
      result("Type \(type) (\(attachment.capitalized) Attachment)")

    case "generatePersonalityContextDictionary":
      let dict: [String: Any] = [
        "results": [
          "attachment_style": suite.string(forKey: "attachment_style") ?? "secure",
          "personality_type": suite.string(forKey: "personality_type") ?? "B"
        ],
        "components": [
          "attachment_style": suite.string(forKey: "attachment_style") ?? "secure",
          "personality_type": suite.string(forKey: "personality_type") ?? "B"
        ],
        "complete": suite.bool(forKey: "personality_test_complete"),
        "emotion": [
          "state": suite.string(forKey: "currentEmotionalState") ?? "neutral_distracted",
          "bucket": suite.string(forKey: "currentEmotionalStateBucket") ?? "moderate",
          "label": suite.string(forKey: "emotionalStateLabel") ?? "Neutral"
        ]
      ]
      result(dict)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
