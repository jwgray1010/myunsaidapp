import UIKit
import Flutter

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        NSLog("[Unsaid][SceneDelegate] willConnectTo session: \(session.configuration.name)")
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            NSLog("[Unsaid][SceneDelegate] ERROR: AppDelegate not available")
            return
        }

        // Build a FlutterViewController from the dedicated engine.
        let flutterVC = FlutterViewController(engine: appDelegate.flutterEngine, nibName: nil, bundle: nil)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = flutterVC
        self.window = window
        window.makeKeyAndVisible()
        NSLog("[Unsaid][SceneDelegate] Window made key & visible (engine attached)")
    }
}