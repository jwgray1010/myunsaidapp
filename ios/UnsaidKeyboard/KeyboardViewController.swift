// KeyboardViewController.swift (extension target)

import UIKit

final class KeyboardViewController: UIInputViewController {
    private var keyboardView: KeyboardController?
    private var hostReady = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create your custom keyboard view
        let kb = KeyboardController(frame: .zero, inputViewStyle: .default)
        kb.translatesAutoresizingMaskIntoConstraints = false

        // Attach it as the inputView and configure
        self.inputView = kb
        kb.configure(with: self)
        self.keyboardView = kb
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hostReady = true
        // If you ever need to toggle the globe visibility, only do it after this point:
        // keyboardView?.setGlobeHidden(!self.needsInputModeSwitchKey)
    }
}
