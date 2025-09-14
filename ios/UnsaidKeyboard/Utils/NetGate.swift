//
//  NetGate.swift
//  UnsaidKeyboard
//
//  Lightweight network monitoring for keyboard extensions
//  Prevents doomed requests, reduces resource usage, and optimizes for mobile networks
//
//  Created by AI Assistant on 9/12/25.
//

import Foundation
import Network

/// Lightweight network monitoring to avoid doomed requests in keyboard extensions
final class NetGate {
    static let shared = NetGate()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "netgate.monitor", qos: .utility)
    private var _online = true
    private var _isExpensive = false
    private var _isConstrained = false
    
    /// Fast, lock-free read of network availability
    var isOnline: Bool { _online }
    
    /// Whether current connection is expensive (cellular)
    var isExpensive: Bool { _isExpensive }
    
    /// Whether device is in Low Data Mode
    var isConstrained: Bool { _isConstrained }
    
    /// Combined check for network suitability for non-critical requests
    var isSuitableForOptionalRequests: Bool {
        isOnline && !isExpensive && !isConstrained
    }
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?._online = (path.status == .satisfied)
            self?._isExpensive = path.isExpensive
            self?._isConstrained = path.isConstrained
            
            // Optional: Log significant network changes for debugging
            #if DEBUG
            let status = path.status == .satisfied ? "connected" : "disconnected"
            let flags = [
                path.isExpensive ? "expensive" : nil,
                path.isConstrained ? "constrained" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            
            if !flags.isEmpty {
                print("🌐 NetGate: \(status) (\(flags))")
            } else {
                print("🌐 NetGate: \(status)")
            }
            #endif
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}

/// Network-related errors for the keyboard extension
enum CommunicatorError: Error, LocalizedError {
    case offline
    case expensiveConnection
    case constrainedConnection
    case timeout
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .offline:
            return "No network connection available"
        case .expensiveConnection:
            return "Cellular connection - request deferred"
        case .constrainedConnection:
            return "Low Data Mode enabled - request deferred"
        case .timeout:
            return "Network request timed out"
        case .invalidResponse:
            return "Invalid server response"
        }
    }
}

/// Extension for easy network checks before making requests
extension NetGate {
    
    /// Throws appropriate error if network is unsuitable for the given request type
    /// - Parameter requiresWiFi: Whether this request should only run on Wi-Fi
    func validateNetworkForRequest(requiresWiFi: Bool = false) throws {
        guard isOnline else {
            throw CommunicatorError.offline
        }
        
        if requiresWiFi && isExpensive {
            throw CommunicatorError.expensiveConnection
        }
        
        if isConstrained {
            throw CommunicatorError.constrainedConnection
        }
    }
    
    /// Quick check for critical requests (tone analysis)
    func canMakeCriticalRequest() -> Bool {
        return isOnline
    }
    
    /// Quick check for optional requests (telemetry, non-critical updates)
    func canMakeOptionalRequest() -> Bool {
        return isSuitableForOptionalRequests
    }
}
