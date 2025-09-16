import UIKit
import Flutter

@objc public class UnsaidKeyboardBridge: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "unsaid_keyboard", binaryMessenger: registrar.messenger())
    let instance = UnsaidKeyboardBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {

    case "isKeyboardAvailable":
      // "Available" just means the extension exists in the bundle
      result(true)

    case "isKeyboardEnabled":
      result(UnsaidKeyboardHelper.isKeyboardEnabled())

    case "getKeyboardStatus":
      result(UnsaidKeyboardHelper.getKeyboardStatus())

    case "openKeyboardSettings":
      Task { @MainActor in
        UnsaidKeyboardHelper.openKeyboardSettings { ok in result(ok) }
      }

    case "requestKeyboardPermissions":
      Task { @MainActor in
        UnsaidKeyboardHelper.openKeyboardSettings { ok in result(ok) }
      }

    case "enableKeyboard", "updateKeyboardSettings":
      // You can't programmatically enable an iOS keyboard — open Settings instead.
      Task { @MainActor in
        UnsaidKeyboardHelper.openKeyboardSettings { ok in result(ok) }
      }

    // If you don't intend to send anything to the extension from Flutter, be explicit:
    case "sendRealtimeToneAnalysis", "sendToneAnalysis", "sendToneAnalysisPayload":
      // Store tone analysis data in shared UserDefaults for keyboard extension
      if let args = call.arguments as? [String: Any],
         let text = args["text"] as? String {
        let sharedDefaults = UserDefaults(suiteName: "group.com.example.unsaid")
        sharedDefaults?.set(args, forKey: "latest_tone_analysis")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "tone_analysis_timestamp")
        result(true)
      } else {
        result(false)
      }

    case "processTextInput":
      // Store text processing request for keyboard extension
      if let args = call.arguments as? [String: Any],
         let text = args["text"] as? String {
        let sharedDefaults = UserDefaults(suiteName: "group.com.example.unsaid")
        sharedDefaults?.set(args, forKey: "latest_text_processing")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "text_processing_timestamp")
        result(text) // Return the processed text
      } else {
        result(call.arguments)
      }

    case "sendCoParentingAnalysis", "sendEQCoaching", "sendChildDevelopmentAnalysis":
      // Store analysis data in shared UserDefaults for keyboard extension
      if let args = call.arguments as? [String: Any] {
        let sharedDefaults = UserDefaults(suiteName: "group.com.example.unsaid")
        let key = "latest_\(call.method)"
        sharedDefaults?.set(args, forKey: key)
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "\(call.method)_timestamp")
        result(true)
      } else {
        result(false)
      }

    case "startKeyboardMonitoring", "stopKeyboardMonitoring":
      // Store monitoring commands for keyboard extension
      let sharedDefaults = UserDefaults(suiteName: "group.com.example.unsaid")
      sharedDefaults?.set(call.method, forKey: "keyboard_monitoring_command")
      sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "monitoring_command_timestamp")
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
