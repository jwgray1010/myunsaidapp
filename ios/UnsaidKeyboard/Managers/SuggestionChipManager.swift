//
//  SuggestionChipManager.swift
//  UnsaidKeyboard
//
//  Manages suggestion chips display and interaction
//

import UIKit
import Foundation
import os.log

@MainActor
protocol SuggestionChipManagerDelegate: AnyObject {
    func suggestionChipDidExpand(_ chip: SuggestionChipView)
    func suggestionChipDidDismiss(_ chip: SuggestionChipView)
}

@MainActor
final class SuggestionChipManager {
    weak var delegate: SuggestionChipManagerDelegate?
    private weak var containerView: UIView?
    private weak var suggestionBar: UIView?
    private var activeChip: SuggestionChipView?
    
    // First-time user tutorial management
    private static let tutorialShownKey = "UnsaidKeyboardTutorialShown"

    init(containerView: UIView) {
        self.containerView = containerView
    }

    func showSuggestion(text: String, tone: ToneStatus) {
        #if DEBUG
        KBDLog("📨 ChipManager: showSuggestion called with text: '\(text)', tone: \(tone)", .debug, "ChipManager")
        #endif
        
        guard let containerView = containerView else { return }

        // ✅ DEFENSIVE COALESCING: Only coalesce if the chip is actually visible on screen
        if let active = activeChip {
            let isOnscreen = (active.superview != nil) && (active.window != nil) && (active.alpha > 0.01)
            let isSameText = active.getCurrentSuggestion() == text
            
            #if DEBUG
            KBDLog("🔍 ChipManager: Active chip found - onscreen: \(isOnscreen), sameText: \(isSameText), text: '\(text)'", .debug, "ChipManager")
            #endif
            
            if isSameText && isOnscreen {
                // Chip is visible and has same text - just refresh styling
                #if DEBUG
                KBDLog("🔄 ChipManager: Refreshing existing chip", .debug, "ChipManager")
                KBDLog("💬 Chip coalesce: onscreen=\(isOnscreen) sameText=\(isSameText)", .debug, "ChipManager")
                #endif
                active.presentSuggestion(text, tone: tone)
                return
            } else if isSameText && !isOnscreen {
                // Chip has same text but is off-screen - clean up and create new one
                KBDLog("🧹 ChipManager: Cleaning up off-screen chip", .debug, "ChipManager")
                activeChip = nil
                // Fall through to create new chip
            } else if !isSameText {
                // Different text - dismiss old chip and create new one
                KBDLog("🔄 ChipManager: Dismissing old chip for new text", .debug, "ChipManager")
                active.onDismissed = { [weak self] in
                    self?.presentNewChip(text: text, tone: tone, in: containerView)
                }
                active.dismiss(animated: true)
                activeChip = nil
                return
            }
        }

        // Create new chip
        KBDLog("🆕 ChipManager: Creating new chip for text: '\(text)'", .debug, "ChipManager")
        presentNewChip(text: text, tone: tone, in: containerView)
    }

    private func presentNewChip(text: String, tone: ToneStatus, in containerView: UIView) {
        KBDLog("🎯 ChipManager: Presenting new chip, clearing any existing active chip", .debug, "ChipManager")
        
        let chip = SuggestionChipView()
        chip.setPreview(text: text, tone: tone, textHash: String(text.hashValue))
        
        // Avoid retain cycles: the chip owns these closures
        chip.onExpanded = { [weak self, weak chip] in 
            guard let self, let chip else { return }
            self.delegate?.suggestionChipDidExpand(chip)
        }
        chip.onDismiss = { [weak self, weak chip] in
            guard let self, let chip else { return }
            self.delegate?.suggestionChipDidDismiss(chip)
            if self.activeChip === chip { 
                #if DEBUG
                KBDLog("🗑️ ChipManager: Clearing active chip reference (user dismissed)", .debug, "ChipManager")
                #endif
                self.activeChip = nil 
            }
        }
        chip.onTimeout = { [weak self, weak chip] in
            guard let self, let chip else { return }
            #if DEBUG
            KBDLog("⏰ ChipManager: Clearing active chip reference (timeout)", .debug, "ChipManager")
            #endif
            if self.activeChip === chip { self.activeChip = nil }
        }
        chip.onDismissed = { [weak self, weak chip] in
            guard let self, let chip else { return }
            KBDLog("🏁 ChipManager: Chip fully dismissed, clearing reference", .debug, "ChipManager")
            if self.activeChip === chip { self.activeChip = nil }
        }

        containerView.addSubview(chip) // layout first
        
        // Remove any old position constraints if you decide to store them.
        // Position chip - prefer *above* suggestion bar, fallback to above keyboard
        if let bar = suggestionBar {
            NSLayoutConstraint.activate([
                chip.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6), // ⬅️ was top = bar.bottom
                chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8)
            ])
        } else {
            if #available(iOS 15.0, *) {
                // Pin just above the keyboard instead of safe area
                NSLayoutConstraint.activate([
                    chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                    chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                    chip.bottomAnchor.constraint(equalTo: containerView.keyboardLayoutGuide.topAnchor, constant: -12)
                ])
            } else {
                // Fallback for iOS < 15: listen to keyboard notifications or keep safeArea
                NSLayoutConstraint.activate([
                    chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                    chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                    chip.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
                ])
            }
        }
        
        // Ensure it's tappable above siblings
        containerView.bringSubviewToFront(chip)
        chip.layer.zPosition = 999
        
        activeChip = chip
        KBDLog("✅ ChipManager: Set new active chip", .debug, "ChipManager")
        KBDLog("💬 Chip present under bar? \(self.suggestionBar != nil)", .debug, "ChipManager")
        chip.present(in: containerView)
    }

    func dismissCurrentChip() {
        activeChip?.dismiss(animated: true)
        activeChip = nil
    }

    func showSuggestionChip(text: String, toneString: String) {
        // Skip tutorial-style messages after first time
        if isTutorialMessage(text) && !shouldShowTutorial() {
            return
        }
        
        showSuggestion(text: text, tone: ToneStatus(from: toneString))
        
        // Mark tutorial as shown if this was a tutorial message
        if isTutorialMessage(text) {
            markTutorialAsShown()
        }
    }
    
    private func isTutorialMessage(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("tone analysis first") ||
               lowercased.contains("touch the tone") ||
               lowercased.contains("tap tone") ||
               lowercased.contains("suggestions will") ||
               lowercased.contains("run tone analysis")
    }

    // ✅ CLEANUP: Remove unused toneButton parameter to avoid confusion
    func configure(suggestionBar: UIView) {
        self.suggestionBar = suggestionBar
    }
    
    // MARK: - Debug Methods
    
    #if DEBUG
    func debugSuggestionChipState() {
        KBDLog("💬 SUGGESTION CHIP MANAGER DEBUG", .debug, "ChipManager")
        KBDLog("================================", .debug, "ChipManager")
        
        KBDLog("💬 Container view: \(containerView != nil ? "exists" : "nil")", .debug, "ChipManager")
        KBDLog("💬 Suggestion bar: \(suggestionBar != nil ? "exists" : "nil")", .debug, "ChipManager")
        KBDLog("💬 Active chip: \(activeChip != nil ? "exists" : "nil")", .debug, "ChipManager")
        
        if let chip = activeChip {
            KBDLog("💬 Active chip superview: \(chip.superview != nil)", .debug, "ChipManager")
            KBDLog("💬 Active chip frame: \(chip.frame)", .debug, "ChipManager")
            KBDLog("💬 Active chip alpha: \(chip.alpha)", .debug, "ChipManager")
            KBDLog("💬 Active chip hidden: \(chip.isHidden)", .debug, "ChipManager")
            KBDLog("💬 Active chip text: '\(chip.getCurrentSuggestion() ?? "nil")'", .debug, "ChipManager")
        }
        
        if let container = containerView {
            KBDLog("💬 Container subviews count: \(container.subviews.count)", .debug, "ChipManager")
            let chipViews = container.subviews.filter { $0 is SuggestionChipView }
            KBDLog("💬 SuggestionChipView instances in container: \(chipViews.count)", .debug, "ChipManager")
        }
        
        KBDLog("💬 Tutorial shown: \(shouldShowTutorial() ? "no" : "yes")", .debug, "ChipManager")
        KBDLog("💬 SUGGESTION CHIP MANAGER DEBUG COMPLETE", .debug, "ChipManager")
    }
    #endif
    
    // MARK: - First-time User Management
    
    private func markTutorialAsShown() {
        // AppGroups.shared already returns a valid UserDefaults (falls back to .standard internally)
        AppGroups.shared.set(true, forKey: Self.tutorialShownKey)
    }
    
    private func shouldShowTutorial() -> Bool {
        return !AppGroups.shared.bool(forKey: Self.tutorialShownKey)
    }
    
    // MARK: - Integration Helper Methods
    
    /// Recover if the suggestion bar is attached later (e.g., after layout)
    func attachSuggestionBarIfNeeded(_ bar: UIView?) {
        if let bar {
            configure(suggestionBar: bar)
            if let chip = activeChip {
                // Re-anchor above the bar
                chip.translatesAutoresizingMaskIntoConstraints = false
                // Remove previous vertical constraints if you're storing them; otherwise rely on Auto Layout conflict resolution:
                NSLayoutConstraint.deactivate(chip.constraints.filter {
                    // crude filter for bottom/vertical constraints you added
                    ($0.firstItem as? UIView) === chip || ($0.secondItem as? UIView) === chip
                })
                NSLayoutConstraint.activate([
                    chip.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
                    chip.leadingAnchor.constraint(equalTo: containerView!.leadingAnchor, constant: 8),
                    chip.trailingAnchor.constraint(equalTo: containerView!.trailingAnchor, constant: -8)
                ])
                containerView?.layoutIfNeeded()
            }
        }
        // If a chip is active and had been anchored to bottom, you could re-layout here if desired
    }
    
    /// Public refresh of tone only (if you get tone updates without new text)
    func updateTone(_ tone: ToneStatus) {
        guard let active = activeChip, let text = active.getCurrentSuggestion() else { return }
        active.presentSuggestion(text, tone: tone)
    }
    
    /// Integration proof method - drop this into any suggestion result handler
    /// to verify end-to-end functionality
    func handleSuggestionResult(text: String, uiToneString: String) {
        showSuggestionChip(text: text, toneString: uiToneString)
        #if DEBUG
        debugSuggestionChipState()
        #endif
    }
    
    /// Test method to verify the entire integration chain
    /// Call this from anywhere to test if chips are working
    func testIntegration() {
        #if DEBUG
        KBDLog("🧪 CHIP INTEGRATION TEST START", .debug, "ChipManager")
        KBDLog("==============================", .debug, "ChipManager")
        
        // Test all tone states
        let testCases = [
            ("Alert tone test suggestion", "alert"),
            ("Caution tone test suggestion", "caution"),
            ("Clear tone test suggestion", "clear"),
            ("Neutral tone test suggestion", "neutral")
        ]
        
        for (index, testCase) in testCases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 2.0) { [weak self] in
                guard let self = self else { return }
                KBDLog("🧪 Testing: \(testCase.0) with tone: \(testCase.1)", .debug, "ChipManager")
                self.showSuggestionChip(text: testCase.0, toneString: testCase.1)
                self.debugSuggestionChipState()
            }
        }
        
        KBDLog("🧪 CHIP INTEGRATION TEST SCHEDULED", .debug, "ChipManager")
        KBDLog("   Watch for chips appearing every 2 seconds...", .debug, "ChipManager")
        #endif
    }
}
