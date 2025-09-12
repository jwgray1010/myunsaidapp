import Foundation
import Network
import os.log

/// WebSocket client for streaming tone updates
/// Responsibilities: connect/reconnect logic, backpressure (drop stale), emit tone updates
/// Does NOT reference Core Haptics - networking only
protocol ToneStreamDelegate: AnyObject {
    func toneStreamDidConnect()
    func toneStreamDidDisconnect()
    func toneStreamDidReceiveToneUpdate(intensity: Float, sharpness: Float)
}

final class ToneStreamClient {
    
    // MARK: - Properties
    weak var delegate: ToneStreamDelegate?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let logger = OSLog(subsystem: "UnsaidKeyboard", category: "ToneStream")
    
    // MARK: - State
    private var isConnected = false
    private var shouldReconnect = true
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 2.0
    
    // MARK: - Backpressure (drop stale updates)
    private var lastUpdateSequence = 0
    private let updateQueue = DispatchQueue(label: "com.unsaid.tonestream", qos: .userInteractive)
    
    // MARK: - Configuration
    private var baseURL: String {
        let base = Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_BASE_URL") as? String ?? ""
        return base.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
    }
    
    private var apiKey: String {
        return Bundle.main.object(forInfoDictionaryKey: "UNSAID_API_KEY") as? String ?? ""
    }
    
    // MARK: - Public API
    
    init() {
        setupURLSession()
    }
    
    deinit {
        disconnect()
    }
    
    /// Connect to tone stream WebSocket
    func connect() {
        guard !isConnected else { return }
        
        os_log("🔌 Connecting to tone stream...", log: logger, type: .info)
        
        guard !baseURL.isEmpty, !apiKey.isEmpty else {
            os_log("❌ Missing WebSocket configuration", log: logger, type: .error)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/ws/tone-stream") else {
            os_log("❌ Invalid WebSocket URL", log: logger, type: .error)
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let task = urlSession?.webSocketTask(with: request)
        webSocketTask = task
        
        task?.resume()
        startReceiving()
        
        // Send initial connection message
        sendConnectionMessage()
    }
    
    /// Disconnect from WebSocket
    func disconnect() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        reconnectAttempts = 0
        
        os_log("🔌 Disconnected from tone stream", log: logger, type: .info)
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.toneStreamDidDisconnect()
        }
    }
    
    /// Send text update to stream for real-time analysis
    func sendTextUpdate(_ text: String) {
        guard isConnected, let task = webSocketTask else { return }
        
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.lastUpdateSequence += 1
            let message: [String: Any] = [
                "type": "text_update",
                "text": text,
                "sequence": self.lastUpdateSequence,
                "timestamp": Date().timeIntervalSince1970
            ]
            
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let jsonString = String(data: data, encoding: .utf8) else {
                return
            }
            
            task.send(.string(jsonString)) { error in
                if let error = error {
                    os_log("❌ Failed to send text update: %{public}@", log: self.logger, type: .error, error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Private Implementation
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        urlSession = URLSession(configuration: config)
    }
    
    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.startReceiving() // Continue receiving
                
            case .failure(let error):
                self?.handleError(error)
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleTextMessage(text)
            }
        @unknown default:
            break
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        updateQueue.async { [weak self] in
            self?.processMessage(json)
        }
    }
    
    private func processMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        
        switch type {
        case "connection_established":
            handleConnectionEstablished()
            
        case "tone_update":
            handleToneUpdate(message)
            
        case "ping":
            sendPong()
            
        default:
            break
        }
    }
    
    private func handleConnectionEstablished() {
        isConnected = true
        reconnectAttempts = 0
        
        os_log("✅ Connected to tone stream", log: logger, type: .info)
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.toneStreamDidConnect()
        }
    }
    
    private func handleToneUpdate(_ message: [String: Any]) {
        guard let sequence = message["sequence"] as? Int,
              sequence >= lastUpdateSequence else {
            // Drop stale updates for backpressure management
            return
        }
        
        let intensity = (message["intensity"] as? NSNumber)?.floatValue ?? 0.5
        let sharpness = (message["sharpness"] as? NSNumber)?.floatValue ?? 0.5
        
        // Clamp values to valid range
        let clampedIntensity = max(0.0, min(1.0, intensity))
        let clampedSharpness = max(0.0, min(1.0, sharpness))
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.toneStreamDidReceiveToneUpdate(
                intensity: clampedIntensity,
                sharpness: clampedSharpness
            )
        }
        
        os_log("📊 Tone update: intensity=%.2f, sharpness=%.2f", 
               log: logger, type: .debug, clampedIntensity, clampedSharpness)
    }
    
    private func sendConnectionMessage() {
        guard let task = webSocketTask else { return }
        
        let message: [String: Any] = [
            "type": "connect",
            "client": "ios_keyboard",
            "version": "1.0"
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        
        task.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                os_log("❌ Failed to send connection message: %{public}@", 
                       log: self?.logger ?? OSLog.disabled, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func sendPong() {
        guard let task = webSocketTask else { return }
        
        let message: [String: Any] = ["type": "pong"]
        
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        
        task.send(.string(jsonString)) { error in
            if let error = error {
                os_log("❌ Failed to send pong: %{public}@", 
                       log: OSLog(subsystem: "UnsaidKeyboard", category: "ToneStream"), 
                       type: .error, error.localizedDescription)
            }
        }
    }
    
    private func handleError(_ error: Error) {
        os_log("❌ WebSocket error: %{public}@", log: logger, type: .error, error.localizedDescription)
        
        isConnected = false
        webSocketTask = nil
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.toneStreamDidDisconnect()
        }
        
        // Attempt reconnection if needed
        if shouldReconnect && reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = reconnectDelay * pow(2.0, Double(reconnectAttempts - 1)) // Exponential backoff
            
            os_log("🔄 Attempting reconnect #%d in %.1fs", log: logger, type: .info, reconnectAttempts, delay)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect()
            }
        }
    }
}
