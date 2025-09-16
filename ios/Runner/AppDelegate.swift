import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Dedicated engine so SceneDelegate can always attach a view controller.
  lazy var flutterEngine: FlutterEngine = {
    let engine = FlutterEngine(name: "primary_engine")

    // Run the engine with default configuration
    engine.run()

    // Register generated plugins directly with the engine.
    GeneratedPluginRegistrant.register(with: engine)
    // Register custom bridges on the engine.
    if let reg = engine.registrar(forPlugin: "KeyboardDataSyncBridge") {
      KeyboardDataSyncBridge.register(with: reg)
    }
    if let reg = engine.registrar(forPlugin: "UnsaidKeyboardBridge") {
      UnsaidKeyboardBridge.register(with: reg)
    }
    if let reg = engine.registrar(forPlugin: "KeyboardAnalyticsBridge") {
      KeyboardAnalyticsBridge.register(with: reg)
    }
    if let reg = engine.registrar(forPlugin: "PersonalityDataBridge") {
      PersonalityDataPlugin.register(with: reg)
    }
    return engine
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
  NSLog("[Unsaid][AppDelegate] didFinishLaunchingWithOptions start (engine initialized)")
    // We don't rely on FlutterAppDelegate creating a window when using scenes.
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    NSLog("[Unsaid][AppDelegate] didFinishLaunchingWithOptions end (super returned: \(result))")
    return result
  }
}
