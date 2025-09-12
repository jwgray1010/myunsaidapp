//
//  HapticsDriver.swift
//  UnsaidKeyboard
//
//  Unified haptics interface - single engine, both transient and continuous patterns
//

import Foundation
import CoreHaptics
import QuartzCore
import os.log

protocol HapticsDriver {
    func start()
    func stop()
    func transient(intensity: Float, sharpness: Float)
    func continuous(intensity: Float, sharpness: Float)
}

/// Unified haptics controller - replaces both ToneHapticsController and HapticFeedbackManager
final class UnifiedHapticsController: HapticsDriver {
    
    // MARK: - State
    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var isEngineStarted = false
    private var isSessionActive = false
    private var isPlayerStarted = false
    private var engineStartCount = 0
    
    // MARK: - Idle Management with Cool-down
    private let idleThreshold: Float = 0.12
    private let meaningfulThreshold: Float = 0.05  // Threshold for starting engine on demand
    private var idleRampWorkItem: DispatchWorkItem?
    private var engineStopWorkItem: DispatchWorkItem?
    
    // MARK: - Smoothing & Throttling
    private var lastIntensity: Float = 0.0
    private var lastSharpness: Float = 0.0
    private var lastUpdateTime: CFTimeInterval = 0
    private let updateThrottleInterval: CFTimeInterval = 0.1 // 10 Hz max
    private let smoothingFactor: Float = 0.3
    private let deadband: Float = 0.05
    
    // MARK: - Metrics (for debugging/monitoring)
    private var startCount = 0
    private var stopCount = 0
    private var updateCount = 0
    private var totalLatency: CFTimeInterval = 0
    private var latencySamples = 0
    
    // MARK: - Queue & Logging
    private let hapticQueue = DispatchQueue(label: "com.unsaid.haptics", qos: .userInteractive)
    
    #if DEBUG
    private let logger = OSLog(subsystem: "UnsaidKeyboard", category: "UnifiedHaptics")
    #endif
    
    // MARK: - Singleton
    static let shared = UnifiedHapticsController()
    
    private init() {
        setupEngine()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - HapticsDriver Implementation
    
    func start() {
        hapticQueue.async { [weak self] in
            self?._startHapticSession()
        }
    }
    
    func stop() {
        hapticQueue.async { [weak self] in
            self?._gracefulStopHapticSession()
        }
    }
    
    // MARK: - Background handling (hard stop for memory pressure)
    func stopForBackground() {
        hapticQueue.async { [weak self] in
            self?._stopHapticSession()
        }
    }
    
    func transient(intensity: Float, sharpness: Float) {
        hapticQueue.async { [weak self] in
            self?._playTransient(intensity: intensity, sharpness: sharpness)
        }
    }
    
    func continuous(intensity: Float, sharpness: Float) {
        let requestTime = CACurrentMediaTime()
        hapticQueue.async { [weak self] in
            self?._applyContinuous(intensity: intensity, sharpness: sharpness, requestTime: requestTime)
        }
    }
    
    // MARK: - Metrics (for debugging and monitoring)
    
    func getMetrics() -> (starts: Int, stops: Int, updates: Int, latencyMs: Double) {
        let avgLatency = latencySamples > 0 ? (totalLatency / Double(latencySamples)) * 1000 : 0
        return (starts: startCount, stops: stopCount, updates: updateCount, latencyMs: avgLatency)
    }
    
    // MARK: - Private Implementation
    
    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            #if DEBUG
            os_log("Haptics not supported on this device", log: logger, type: .info)
            #endif
            return
        }
        
        do {
            hapticEngine = try CHHapticEngine()
            setupEngineHandlers()
            #if DEBUG
            os_log("Unified haptic engine created", log: logger, type: .info)
            #endif
        } catch {
            #if DEBUG
            os_log("Failed to create haptic engine: %{public}@", log: logger, type: .error, error.localizedDescription)
            #endif
        }
    }
    
    private func setupEngineHandlers() {
        guard let engine = hapticEngine else { return }
        
        engine.stoppedHandler = { [weak self] reason in
            #if DEBUG
            os_log("Haptic engine stopped: %{public}@", log: self?.logger ?? OSLog.disabled, type: .info, String(describing: reason))
            #endif
            self?.isEngineStarted = false
            
            if reason == .audioSessionInterrupt || reason == .applicationSuspended {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.restartEngineIfNeeded()
                }
            }
        }
        
        engine.resetHandler = { [weak self] in
            #if DEBUG
            os_log("Haptic engine reset", log: self?.logger ?? OSLog.disabled, type: .info)
            #endif
            self?.isEngineStarted = false
            self?.restartEngineIfNeeded()
        }
    }
    
    private func restartEngineIfNeeded() {
        hapticQueue.async { [weak self] in
            guard let self = self, self.isSessionActive && !self.isEngineStarted else { return }
            self._startHapticSession()
        }
    }
    
    private func _startHapticSession() {
        isSessionActive = true
        // Don't start engine immediately - wait for first meaningful tone
        #if DEBUG
        os_log("Haptic session ready (engine will start on demand)", log: logger, type: .info)
        #endif
    }
    
    private func _startEngineIfNeeded() {
        guard let engine = hapticEngine, !isEngineStarted else { return }
        do {
            engine.playsHapticsOnly = true // keeps audio session light (safe in extensions)
            try engine.start()
            isEngineStarted = true
            engineStartCount += 1
            if continuousPlayer == nil { createContinuousPlayer() }
            #if DEBUG
            os_log("Haptic engine started on demand (start #%d)", log: logger, type: .info, engineStartCount)
            #endif
        } catch {
            #if DEBUG
            os_log("Engine start failed: %{public}@", log: logger, type: .error, error.localizedDescription)
            #endif
        }
    }
    
    private func _gracefulStopHapticSession() {
        // Cancel timers and schedule idle shutdown instead of hard-stopping immediately
        idleRampWorkItem?.cancel()
        engineStopWorkItem?.cancel()
        
        isSessionActive = false
        
        // Schedule graceful shutdown
        scheduleIdleTimers()
        
        #if DEBUG
        os_log("Haptic session stopping gracefully", log: logger, type: .info)
        #endif
    }
    
    private func _stopHapticSession() {
        // Cancel any pending idle timers
        idleRampWorkItem?.cancel()
        engineStopWorkItem?.cancel()
        
        isSessionActive = false
        isPlayerStarted = false
        stopCount += 1 // Track stops
        
        // For hard stop (like backgrounding), immediately stop everything
        _stopHapticEngineOnly()
        
        // Stop continuous player
        if let player = continuousPlayer {
            do {
                try player.stop(atTime: CHHapticTimeImmediate)
                continuousPlayer = nil
            } catch {
                #if DEBUG
                os_log("Failed to stop continuous player: %{public}@", log: logger, type: .error, error.localizedDescription)
                #endif
            }
        }
    }
    
    private func scheduleIdleTimers() {
        idleRampWorkItem?.cancel()
        engineStopWorkItem?.cancel()

        // 1) Ramp to zero & stop player after brief idle
        let ramp = DispatchWorkItem { [weak self] in
            guard let self, let player = self.continuousPlayer, self.isPlayerStarted else { return }
            do {
                try player.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.0, relativeTime: 0),
                    CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: 0.0, relativeTime: 0)
                ], atTime: CHHapticTimeImmediate)
                try player.stop(atTime: CHHapticTimeImmediate)
                self.isPlayerStarted = false
                #if DEBUG
                os_log("Player ramped to zero and stopped due to idle", log: self.logger, type: .debug)
                #endif
            } catch {
                #if DEBUG
                os_log("Idle ramp/stop failed: %{public}@", log: self.logger, type: .error, error.localizedDescription)
                #endif
            }
        }
        idleRampWorkItem = ramp
        hapticQueue.asyncAfter(deadline: .now() + 1.5, execute: ramp)

        // 2) Stop engine later (avoid churn)
        let stop = DispatchWorkItem { [weak self] in
            self?._stopHapticEngineOnly()
        }
        engineStopWorkItem = stop
        hapticQueue.asyncAfter(deadline: .now() + 6.0, execute: stop)
    }

    private func _stopHapticEngineOnly() {
        guard let engine = hapticEngine, isEngineStarted else { return }
        engine.stop { [weak self] _ in
            self?.isEngineStarted = false
            #if DEBUG
            os_log("Haptic engine stopped after idle timeout", log: self?.logger ?? OSLog.disabled, type: .debug)
            #endif
        }
    }
    
    // MARK: - Transient Haptics (for UI feedback with lazy engine start)
    
    private func _playTransient(intensity: Float, sharpness: Float) {
        guard isSessionActive, let engine = hapticEngine else { return }
        
        do {
            // Start engine if needed for meaningful transient feedback
            if !isEngineStarted {
                _startEngineIfNeeded()
            }
            
            let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: 0
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            
        } catch {
            #if DEBUG
            os_log("Failed to play transient haptic: %{public}@", log: logger, type: .error, error.localizedDescription)
            #endif
        }
    }
    
    // MARK: - Continuous Haptics (with lazy engine start and idle management)
    
    private func _applyContinuous(intensity: Float, sharpness: Float, requestTime: CFTimeInterval) {
        guard isSessionActive else { return }
        
        let now = CACurrentMediaTime()
        
        // Cancel any pending idle timers since we have activity
        idleRampWorkItem?.cancel()
        engineStopWorkItem?.cancel()
        
        // Throttle updates to 10 Hz
        if now - lastUpdateTime < updateThrottleInterval {
            return
        }
        
        // Apply smoothing
        let smoothedIntensity = lastIntensity + smoothingFactor * (intensity - lastIntensity)
        let smoothedSharpness = lastSharpness + smoothingFactor * (sharpness - lastSharpness)
        
        // Apply deadband
        let intensityDelta = abs(smoothedIntensity - lastIntensity)
        let sharpnessDelta = abs(smoothedSharpness - lastSharpness)
        
        if intensityDelta < deadband && sharpnessDelta < deadband {
            // Still schedule idle timers even for small changes
            scheduleIdleTimers()
            return
        }
        
        // Track metrics
        updateCount += 1
        let latency = now - requestTime
        totalLatency += latency
        latencySamples += 1
        
        // Check if this is meaningful enough to start engine
        let activeMag = max(smoothedIntensity, smoothedSharpness)
        if activeMag >= meaningfulThreshold {
            // Start engine if needed on first meaningful tone
            if !isEngineStarted {
                _startEngineIfNeeded()
            }
            
            // Recreate continuous player if needed
            if continuousPlayer == nil {
                createContinuousPlayer()
            }
            
            // Start player if not started
            if !isPlayerStarted, let player = continuousPlayer {
                do {
                    try player.start(atTime: CHHapticTimeImmediate)
                    isPlayerStarted = true
                    #if DEBUG
                    os_log("Continuous player started for meaningful tone", log: logger, type: .debug)
                    #endif
                } catch {
                    #if DEBUG
                    os_log("Failed to start continuous player: %{public}@", log: logger, type: .error, error.localizedDescription)
                    #endif
                }
            }
            
            // Update parameters if player is active
            if isPlayerStarted, let player = continuousPlayer {
                do {
                    let intensityParam = CHHapticDynamicParameter(
                        parameterID: .hapticIntensityControl,
                        value: smoothedIntensity,
                        relativeTime: 0
                    )
                    
                    let sharpnessParam = CHHapticDynamicParameter(
                        parameterID: .hapticSharpnessControl,
                        value: smoothedSharpness,
                        relativeTime: 0
                    )
                    
                    try player.sendParameters([intensityParam, sharpnessParam], atTime: CHHapticTimeImmediate)
                    
                    lastIntensity = smoothedIntensity
                    lastSharpness = smoothedSharpness
                    lastUpdateTime = now
                    
                } catch {
                    #if DEBUG
                    os_log("Failed to update continuous haptic parameters: %{public}@", log: logger, type: .error, error.localizedDescription)
                    #endif
                }
            }
        }
        
        // Schedule idle timers for this update
        scheduleIdleTimers()
    }
    
    private func createContinuousPlayer() {
        guard let engine = hapticEngine else { return }
        
        do {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.0)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0)
            
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: 3600
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
            
            #if DEBUG
            os_log("Continuous haptic player created", log: logger, type: .info)
            #endif
            
        } catch {
            #if DEBUG
            os_log("Failed to create continuous player: %{public}@", log: logger, type: .error, error.localizedDescription)
            #endif
        }
    }
    
    // MARK: - Convenience Methods for Common UI Patterns
    
    func lightTap() { transient(intensity: 0.3, sharpness: 0.3) }
    func mediumTap() { transient(intensity: 0.6, sharpness: 0.6) }
    func heavyTap() { transient(intensity: 1.0, sharpness: 1.0) }
    func selection() { transient(intensity: 0.4, sharpness: 0.8) }
    
    // MARK: - Advanced Haptic Patterns (from AdvancedHapticEngine)
    
    func playAttentionPattern() {
        hapticQueue.async { [weak self] in
            // Triple tap for attention
            self?._playTransient(intensity: 1.0, sharpness: 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?._playTransient(intensity: 1.0, sharpness: 1.0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?._playTransient(intensity: 1.0, sharpness: 1.0)
            }
        }
    }
    
    func playProgressPattern(progress: Float) {
        let clampedProgress = max(0.0, min(1.0, progress))
        continuous(intensity: clampedProgress, sharpness: 0.5)
    }
    
    func playSuccessPattern() {
        hapticQueue.async { [weak self] in
            // Success: medium-light-medium
            self?._playTransient(intensity: 0.7, sharpness: 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?._playTransient(intensity: 0.4, sharpness: 0.3)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?._playTransient(intensity: 0.7, sharpness: 0.6)
            }
        }
    }
    
    func playWarningPattern() {
        hapticQueue.async { [weak self] in
            // Warning: two sharp taps
            self?._playTransient(intensity: 0.8, sharpness: 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?._playTransient(intensity: 0.8, sharpness: 1.0)
            }
        }
    }
    
    func playErrorPattern() {
        hapticQueue.async { [weak self] in
            // Error: long heavy vibration
            guard let self = self, self.isSessionActive, let engine = self.hapticEngine else { return }
            
            do {
                if !self.isEngineStarted {
                    self._startEngineIfNeeded()
                }
                
                let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
                let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [intensity, sharpness],
                    relativeTime: 0,
                    duration: 0.5
                )
                
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                
            } catch {
                #if DEBUG
                os_log("Failed to play error pattern: %{public}@", log: self.logger, type: .error, error.localizedDescription)
                #endif
            }
        }
    }
}

// MARK: - WebSocket Haptic Coordination (Simplified)

protocol HapticWebSocketDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceiveHapticUpdate(intensity: Float, sharpness: Float)
    func webSocketDidReceiveError(_ error: Error)
}

/// Lightweight WebSocket client for haptic coordination (keyboard extension optimized)
final class HapticWebSocketClient {
    
    weak var delegate: HapticWebSocketDelegate?
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 2 // Limited for keyboard extension
    private var idleTimer: Timer?
    private let idleTimeout: TimeInterval = 10.0 // 10s idle timeout
    
    #if DEBUG
    private let logger = OSLog(subsystem: "UnsaidKeyboard", category: "HapticWebSocket")
    #endif
    
    init() {
        // Ephemeral configuration for keyboard extension
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }
    
    deinit {
        disconnect()
    }
    
    func connect(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        disconnect() // Clean state
        
        var request = URLRequest(url: url)
        request.setValue("haptic-keyboard-ios", forHTTPHeaderField: "User-Agent")
        
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        
        listenForMessages()
        startIdleTimer()
        
        #if DEBUG
        os_log("Connecting to haptic WebSocket", log: logger, type: .info)
        #endif
    }
    
    func disconnect() {
        idleTimer?.invalidate()
        idleTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        if isConnected {
            isConnected = false
            delegate?.webSocketDidDisconnect(error: nil)
        }
    }
    
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.resetIdleTimer()
                self?.handleMessage(message)
                self?.listenForMessages()
                
            case .failure(let error):
                self?.handleConnectionError(error)
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "haptic_update":
            if let intensity = json["intensity"] as? Float,
               let sharpness = json["sharpness"] as? Float {
                DispatchQueue.main.async {
                    self.delegate?.webSocketDidReceiveHapticUpdate(intensity: intensity, sharpness: sharpness)
                }
            }
            
        case "connection_established":
            if !isConnected {
                isConnected = true
                reconnectAttempts = 0
                DispatchQueue.main.async {
                    self.delegate?.webSocketDidConnect()
                }
            }
            
        default:
            break
        }
    }
    
    private func handleConnectionError(_ error: Error) {
        isConnected = false
        
        DispatchQueue.main.async {
            self.delegate?.webSocketDidDisconnect(error: error)
        }
        
        // Limited reconnect for keyboard extension
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(reconnectAttempts * 2)) {
                // Would need stored URL to reconnect
            }
        }
    }
    
    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            self?.disconnect()
        }
    }
    
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        startIdleTimer()
    }
    
    func sendHapticRequest(intensity: Float, sharpness: Float) {
        guard let webSocketTask = webSocketTask, isConnected else { return }
        
        let message: [String: Any] = [
            "type": "haptic_request",
            "intensity": intensity,
            "sharpness": sharpness
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: message) {
            let wsMessage = URLSessionWebSocketTask.Message.data(data)
            webSocketTask.send(wsMessage) { _ in }
        }
    }
}

// MARK: - Tone Mapping Helper

extension UnifiedHapticsController {
    
    /// Convert tone status to haptic parameters
    static func toneToHaptics(_ toneStatusString: String) -> (intensity: Float, sharpness: Float) {
        switch toneStatusString.lowercased() {
        case "clear":
            return (intensity: 0.3, sharpness: 0.3) // Light, soft
        case "caution":
            return (intensity: 0.6, sharpness: 0.7) // Medium, sharp
        case "alert":
            return (intensity: 0.9, sharpness: 1.0) // Strong, very sharp
        case "neutral":
            return (intensity: 0.0, sharpness: 0.0) // No haptics
        default:
            return (intensity: 0.0, sharpness: 0.0) // No haptics for unknown
        }
    }
    
    /// Apply tone-based continuous haptics with proper throttling
    func applyTone(intensity: Float, sharpness: Float) {
        continuous(intensity: intensity, sharpness: sharpness)
    }
    
    /// Start haptic session (alias for backwards compatibility)
    func startHapticSession() {
        start()
    }
    
    /// Stop haptic session (alias for backwards compatibility)
    func stopHapticSession() {
        stop()
    }
}
