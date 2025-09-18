// KeyboardViewController.swift (extension target)

import UIKit

final class KeyboardViewController: UIInputViewController {
    private var keyboardView: KeyboardController?
    private var hostReady = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create your custom keyboard view
        let kb = KeyboardController(frame: .zero, inputViewStyle: .keyboard)
        kb.translatesAutoresizingMaskIntoConstraints = false

        // Add as subview and constrain to full view size for proper width
        view.addSubview(kb)
        NSLayoutConstraint.activate([
            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.topAnchor.constraint(equalTo: view.topAnchor),
            kb.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Configure the keyboard
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
