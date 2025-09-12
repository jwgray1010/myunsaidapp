//
//  TimerHub.swift
//  UnsaidKeyboard
//
//  Unified timer system to reduce runloop wakeups and improve performance
//

import Foundation
import Dispatch

/// Token for timer identification and cancellation
struct TimerToken: Hashable {
    private let id = UUID()
}

/// Unified timer hub to replace separate Timer instances across the keyboard
final class TimerHub {
    
    // MARK: - Singleton
    static let shared = TimerHub()
    
    // MARK: - State
    private let queue = DispatchQueue.main
    private var scheduledTimers: [TimerToken: DispatchSourceTimer] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    deinit {
        cancelAll()
    }
    
    // MARK: - Public API
    
    /// Schedule a timer to fire after a delay
    /// - Parameters:
    ///   - delay: Time interval to wait before firing
    ///   - action: Block to execute when timer fires
    /// - Returns: Token that can be used to cancel the timer
    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> TimerToken {
        let token = TimerToken()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.remove(token: token)
            action()
        }
        
        lock.lock()
        scheduledTimers[token] = timer
        lock.unlock()
        
        timer.resume()
        return token
    }
    
    /// Schedule a repeating timer
    /// - Parameters:
    ///   - interval: Time interval between fires
    ///   - action: Block to execute when timer fires
    /// - Returns: Token that can be used to cancel the timer
    @discardableResult
    func scheduleRepeating(interval: TimeInterval, action: @escaping () -> Void) -> TimerToken {
        let token = TimerToken()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            action()
        }
        
        lock.lock()
        scheduledTimers[token] = timer
        lock.unlock()
        
        timer.resume()
        return token
    }
    
    /// Cancel a specific timer
    /// - Parameter token: Timer token to cancel
    func cancel(token: TimerToken) {
        remove(token: token)
    }
    
    /// Cancel all active timers
    func cancelAll() {
        lock.lock()
        let timers = scheduledTimers
        scheduledTimers.removeAll()
        lock.unlock()
        
        for (_, timer) in timers {
            timer.cancel()
        }
    }
    
    // MARK: - Private
    
    private func remove(token: TimerToken) {
        lock.lock()
        let timer = scheduledTimers.removeValue(forKey: token)
        lock.unlock()
        
        timer?.cancel()
    }
}

// MARK: - Convenience Extensions

extension TimerHub {
    
    /// Schedule a one-shot timer with weak reference protection
    @discardableResult
    func schedule<T: AnyObject>(
        after delay: TimeInterval,
        target: T,
        action: @escaping (T) -> () -> Void
    ) -> TimerToken {
        return schedule(after: delay) { [weak target] in
            guard let target = target else { return }
            action(target)()
        }
    }
    
    /// Schedule a repeating timer with weak reference protection
    @discardableResult
    func scheduleRepeating<T: AnyObject>(
        interval: TimeInterval,
        target: T,
        action: @escaping (T) -> () -> Void
    ) -> TimerToken {
        return scheduleRepeating(interval: interval) { [weak target] in
            guard let target = target else { return }
            action(target)()
        }
    }
}
