import UIKit
import Flutter

@objc public class KeyboardAnalyticsBridge: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.unsaid/keyboard_analytics", binaryMessenger: registrar.messenger())
    let instance = KeyboardAnalyticsBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getKeyboardAnalytics":    
      result([:])      // return empty map
    case "getKeyboardInteractions": 
      result([])       // return empty list
    case "syncChildrenNames":       
      result(true)
    default:                        
      result(FlutterMethodNotImplemented)
    }
  }
}
