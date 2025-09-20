//
//  NetworkGate.swift
//  UnsaidKeyboard
//
//  Network reachability monitoring for keyboard extension
//

import Foundation
import Network

final class NetworkGate {
    static let shared = NetworkGate()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "kbd.net.monitor")
    private(set) var isReachable = false
    private var started = false
    
    private init() {}
    
    func start(onStatus: @escaping (Bool) -> Void) {
        guard !started else { 
            print("🌐 NetworkGate: Already started, ignoring duplicate start request")
            return 
        }
        started = true
        
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = (path.status == .satisfied)
            self?.isReachable = ok
            print("🌐 NetworkGate: Reachability changed to \(ok ? "✅ ONLINE" : "❌ OFFLINE")")
            onStatus(ok)
        }
        monitor.start(queue: queue)
    }
    
    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }
    
    deinit {
        stop()
    }
}