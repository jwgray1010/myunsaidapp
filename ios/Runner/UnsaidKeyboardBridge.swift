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
      result(true)
    case "isKeyboardEnabled":  
      result(true)
    case "enableKeyboard":     
      result(true)
    case "getKeyboardStatus":  
      result(["active": true])
    case "openKeyboardSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(true)
    case "requestKeyboardPermissions":
      result(true)
    case "updateKeyboardSettings":
      result(true)
    case "sendToneAnalysisPayload":
      result(true)
    case "processTextInput":
      if let args = call.arguments as? String {
        result(args) // Echo back for now
      } else {
        result("")
      }
    case "sendCoParentingAnalysis":
      result(true)
    case "sendEQCoaching":
      result(true)
    case "sendChildDevelopmentAnalysis":
      result(true)
    default:
      // For now, acknowledge other methods so the app doesn't crash during dev
      result(true)
    }
  }
}
