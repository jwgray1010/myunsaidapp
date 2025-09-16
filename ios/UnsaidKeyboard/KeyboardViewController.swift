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
    private var toneAnalysisTimer: Timer?
    private var lastToneAnalysisTimestamp: TimeInterval = 0
    
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
        let appGroupId = "group.com.example.unsaid"
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            logger.error("❌ App Group not accessible: \(appGroupId)")
            debugLabel.text = "App Group Error"
            debugLabel.backgroundColor = .systemRed
            return
        }
        
        // App Group test
        sharedDefaults.set("test_value", forKey: "debug_test")
        let retrieved = sharedDefaults.string(forKey: "debug_test")
        logger.info("✅ App Group test successful: \(retrieved ?? "nil")")
        
        // Initialize durable user ID for API access
        initializeUserId()
        
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
                
                // Start monitoring for tone analysis data from Flutter
                self.startToneAnalysisMonitoring()
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
    
    // MARK: - User ID Initialization
    
    /// Initialize a durable user ID for API access
    /// This ensures we never send 'anonymous' as userId to the trial guard
    private func initializeUserId() {
        let userIdKey = "unsaid_user_id"
        let appGroupId = "group.com.example.unsaid"
        
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            logger.error("❌ Failed to access shared UserDefaults with suite: \(appGroupId)")
            return
        }
        
        // Check if we already have a user ID
        if sharedDefaults.string(forKey: userIdKey) == nil {
            // Generate and store a new UUID
            let newUserId = UUID().uuidString
            sharedDefaults.set(newUserId, forKey: userIdKey)
            logger.info("🆔 Generated new user ID: \(newUserId)")
        } else {
            let existingUserId = sharedDefaults.string(forKey: userIdKey) ?? "unknown"
            logger.info("🆔 Using existing user ID: \(existingUserId)")
        }
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        logger.debug("📝 KeyboardViewController.textDidChange")
        // KeyboardController will get the textDocumentProxy changes automatically
    }
    
    // MARK: - Tone Analysis Monitoring
    
    /// Start monitoring for tone analysis data from Flutter app
    private func startToneAnalysisMonitoring() {
        logger.info("🎯 Starting tone analysis monitoring")
        
        // Check immediately for any pending data
        checkForToneAnalysisData()
        
        // Set up timer to check every 0.5 seconds
        toneAnalysisTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForToneAnalysisData()
        }
    }
    
    /// Check shared UserDefaults for new tone analysis data from Flutter
    private func checkForToneAnalysisData() {
        let appGroupId = "group.com.example.unsaid"
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            logger.error("❌ Cannot access shared UserDefaults for tone analysis")
            return
        }
        
        // Check for tone analysis timestamp
        let timestamp = sharedDefaults.double(forKey: "tone_analysis_timestamp")
        if timestamp > lastToneAnalysisTimestamp {
            lastToneAnalysisTimestamp = timestamp
            logger.info("🎯 New tone analysis data detected at timestamp: \(timestamp)")
            
            // Get the tone analysis data
            if let toneData = sharedDefaults.dictionary(forKey: "latest_tone_analysis") {
                processToneAnalysisData(toneData)
            }
        }
        
        // Also check for other analysis types
        checkForOtherAnalysisData(sharedDefaults)
    }
    
    /// Process tone analysis data received from Flutter
    private func processToneAnalysisData(_ data: [String: Any]) {
        logger.info("🎯 Processing tone analysis data: \(data)")
        
        // Extract tone information
        if let analysis = data["analysis"] as? [String: Any],
           let tone = analysis["dominant_tone"] as? String {
            logger.info("🎯 Extracted tone: \(tone)")
            
            // Trigger tone update in keyboard controller
            DispatchQueue.main.async { [weak self] in
                self?.keyboardController?.updateToneFromAnalysis(analysis)
            }
        } else if let tone = data["tone"] as? String {
            logger.info("🎯 Direct tone: \(tone)")
            
            // Trigger tone update in keyboard controller
            DispatchQueue.main.async { [weak self] in
                self?.keyboardController?.updateToneFromAnalysis(["dominant_tone": tone])
            }
        }
    }
    
    /// Check for other types of analysis data
    private func checkForOtherAnalysisData(_ sharedDefaults: UserDefaults) {
        // Check for co-parenting analysis
        if let coParentingData = sharedDefaults.dictionary(forKey: "latest_sendCoParentingAnalysis") {
            logger.info("👨‍👩‍👧‍👦 Co-parenting analysis data received")
            // Process co-parenting data if needed
        }
        
        // Check for EQ coaching
        if let eqData = sharedDefaults.dictionary(forKey: "latest_sendEQCoaching") {
            logger.info("🧠 EQ coaching data received")
            // Process EQ data if needed
        }
        
        // Check for child development analysis
        if let childData = sharedDefaults.dictionary(forKey: "latest_sendChildDevelopmentAnalysis") {
            logger.info("👶 Child development analysis data received")
            // Process child development data if needed
        }
    }
    
    deinit {
        toneAnalysisTimer?.invalidate()
        logger.info("🗑️ KeyboardViewController deinitialized")
    }
}
