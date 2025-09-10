//
//  DeleteManager.swift
//  UnsaidKeyboard
//
//  Lightweight delete repeat with gentle acceleration
//

import Foundation
import UIKit

@MainActor
protocol DeleteManagerDelegate: AnyObject {
    func performDelete()          // immediate delete on key down
    func performDeleteTick()      // repeated deletes while holding
    func hapticLight()            // optional; no-op if you don't implement
}

@MainActor
final class DeleteManager {
    weak var delegate: DeleteManagerDelegate?

    // Repeat timers
    private var initialDelayTimer: Timer?
    private var repeatTimer: Timer?

    // Acceleration
    private let baseInterval: TimeInterval = 0.12     // start speed
    private let minInterval: TimeInterval = 0.04      // cap speed
    private let accelFactor: Double = 0.92            // 8% faster each step
    private var currentInterval: TimeInterval = 0.12

    // State
    private let initialDelay: TimeInterval = 0.5      // iOS-like hold delay
    private let enableHaptics = false                 // flip to true if desired

    init() {}

    deinit { 
        Task { @MainActor in
            stopDeleteRepeat()
        }
    }

    // MARK: - Public

    func beginDeleteRepeat() {
        // Debounce: ignore if we're already handling this press
        guard initialDelayTimer == nil && repeatTimer == nil else { return }

        currentInterval = baseInterval

        // Immediate single delete on key down
        delegate?.performDelete()

        // Schedule initial delay before autorepeat kicks in
        let t = Timer(timeInterval: initialDelay, repeats: false) { [weak self] _ in
            self?.startRepeating()
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        initialDelayTimer = t
    }

    func endDeleteRepeat() {
        stopDeleteRepeat()
    }

    // MARK: - Internals

    private func startRepeating() {
        // If the user lifted during the delay, bail
        guard initialDelayTimer != nil && repeatTimer == nil else { return }

        initialDelayTimer?.invalidate()
        initialDelayTimer = nil
        if enableHaptics { delegate?.hapticLight() }

        // Start repeat timer
        scheduleRepeatTimer(interval: currentInterval)
    }

    private func scheduleRepeatTimer(interval: TimeInterval) {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleRepeatTick()
        }
        t.tolerance = max(0.25 * interval, 0.005)  // energy-friendly, still responsive
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func handleRepeatTick() {
        delegate?.performDeleteTick()

        // accelerate gently until minInterval
        guard currentInterval > minInterval else { return }
        currentInterval = max(minInterval, currentInterval * accelFactor)

        // Re-arm timer only when interval actually changed meaningfully
        repeatTimer?.invalidate()
        repeatTimer = nil
        scheduleRepeatTimer(interval: currentInterval)
    }

    private func stopDeleteRepeat() {
        initialDelayTimer?.invalidate()
        repeatTimer?.invalidate()
        initialDelayTimer = nil
        repeatTimer = nil

        // Reset for next press
        currentInterval = baseInterval
    }
}
