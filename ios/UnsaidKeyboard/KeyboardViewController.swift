//  KeyboardViewController.swift
//  UnsaidKeyboard (Extension target)

import UIKit

final class KeyboardViewController: UIInputViewController {
    private var keyboardView: KeyboardController?
    private var heightConstraint: NSLayoutConstraint?
    private var hostReady = false

    // Tune this if you want a different default height
    private let defaultKeyboardHeight: CGFloat = 286

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Let the system size the host input view; do NOT turn off Auto Layout here.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insetsLayoutMarginsFromSafeArea = false

        // Kill any inherited margins/insets that can create a trailing gutter.
        inputView?.preservesSuperviewLayoutMargins = false
        inputView?.directionalLayoutMargins = .zero

        // Make the system input view transparent so your UI shows edge-to-edge.
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear

        // Create your custom keyboard root (must be a UIView subclass).
        let kb = KeyboardController(frame: .zero)
        kb.translatesAutoresizingMaskIntoConstraints = false
        kb.backgroundColor = .systemBackground   // prevents any gray bleed-through
        view.addSubview(kb)

        // Pin to all edges of the host view.
        NSLayoutConstraint.activate([
            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kb.topAnchor.constraint(equalTo: view.topAnchor),
            kb.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Give the container a concrete height (system will respect this).
        // You can remove this if KeyboardController provides an intrinsic height.
        let h = view.heightAnchor.constraint(equalToConstant: defaultKeyboardHeight)
        h.priority = .defaultHigh
        h.isActive = true
        heightConstraint = h

        // Wire up delegates/services inside the keyboard.
        kb.configure(with: self)
        self.keyboardView = kb
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hostReady = true

        // Build/attach anything that should only happen once we’re on-screen
        keyboardView?.hostDidAppear()

        // If you need to toggle the globe, do it here (example):
        // keyboardView?.setGlobeHidden(!self.needsInputModeSwitchKey)
    }

    // MARK: - Adapt to environment changes

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Keep margins flat; prevents mysterious side insets on some devices.
        view.insetsLayoutMarginsFromSafeArea = false
        inputView?.preservesSuperviewLayoutMargins = false
        inputView?.directionalLayoutMargins = .zero
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Optional: adjust height for landscape/portrait if desired
        coordinator.animate(alongsideTransition: { _ in
            // Example: slightly thinner in landscape
            if size.width > size.height {
                self.heightConstraint?.constant = max(240, self.defaultKeyboardHeight - 36)
            } else {
                self.heightConstraint?.constant = self.defaultKeyboardHeight
            }
            self.view.layoutIfNeeded()
        })
    }
    
    // MARK: - Text Change Notifications
    
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Forward text change notifications to our keyboard controller
        keyboardView?.textDidChange()
    }
    
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        // Forward selection change notifications (can also indicate text changes)
        keyboardView?.textDidChange()
    }
}
