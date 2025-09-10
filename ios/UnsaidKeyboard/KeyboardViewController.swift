//
//  KeyboardViewController.swift
//  UnsaidKeyboard
//
//  Created by John  Gray on 8/22/25.
//

import UIKit
import os.log

class KeyboardViewController: UIInputViewController {
    
    private var keyboardController: KeyboardController?
    private let logger = Logger(subsystem: "com.example.unsaid.UnsaidKeyboard", category: "KeyboardViewController")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        logger.info("🚀 KeyboardViewController.viewDidLoad() starting...")
        
        // Set a visible background to distinguish between loaded view vs. crash black screen
        view.backgroundColor = .systemBackground
        logger.info("✅ Background color set")
        
        // Add a visible label to confirm the view loaded
        let debugLabel = UILabel()
        debugLabel.text = "Keyboard Loading..."
        debugLabel.textAlignment = .center
        debugLabel.backgroundColor = .systemBlue
        debugLabel.textColor = .white
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugLabel)
        NSLayoutConstraint.activate([
            debugLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            debugLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            debugLabel.widthAnchor.constraint(equalToConstant: 200),
            debugLabel.heightAnchor.constraint(equalToConstant: 44)
        ])
        logger.info("✅ Debug label added")
        
        // Test App Group access early
    // App Group test (AppGroups.shared already handles fallback)
    AppGroups.shared.set("test_value", forKey: "debug_test")
    let retrieved = AppGroups.shared.string(forKey: "debug_test")
    logger.info("✅ App Group test successful: \(retrieved ?? "nil")")
        
        // Initialize the custom keyboard controller
        logger.info("🔧 Creating KeyboardController...")
        keyboardController = KeyboardController(frame: view.bounds, inputViewStyle: .default)
        logger.info("✅ KeyboardController created successfully")
        
        logger.info("🔧 Configuring KeyboardController...")
        keyboardController?.configure(with: self)
        logger.info("✅ KeyboardController configured successfully")
        
        // Set up the keyboard view with error handling
        if let keyboardView = keyboardController {
            logger.info("🔧 Assigning KeyboardController to inputView...")
            self.inputView = keyboardView
            logger.info("✅ KeyboardController assigned to inputView")
            
            // Hide debug label after successful setup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                debugLabel.removeFromSuperview()
                self.logger.info("✅ KeyboardViewController setup complete!")
            }
        } else {
            logger.error("❌ KeyboardController is nil - setup failed")
            debugLabel.text = "Controller is nil"
            debugLabel.backgroundColor = .systemRed
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        logger.info("📱 KeyboardViewController.viewWillAppear")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        logger.info("📱 KeyboardViewController.viewDidAppear")
    }
    
    override func updateViewConstraints() {
        super.updateViewConstraints()
        logger.debug("🔧 KeyboardViewController.updateViewConstraints")
        // KeyboardController handles its own constraints
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        logger.debug("🔧 KeyboardViewController.viewWillLayoutSubviews")
        // Let Auto Layout constraints handle the layout
    }
    
    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        logger.debug("📝 KeyboardViewController.textWillChange")
        // KeyboardController will get the textDocumentProxy changes automatically
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        logger.debug("📝 KeyboardViewController.textDidChange")
        // KeyboardController will get the textDocumentProxy changes automatically
    }
}
