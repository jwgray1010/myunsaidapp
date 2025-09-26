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
    
    // 🔒 When true, only explicit button taps may show chips.
    private var requireExplicitTap = true  // Start with true - chips only on tone button tap
    
    // First-time user tutorial management
    private static let tutorialShownKey = "UnsaidKeyboardTutorialShown"

    enum SuggestionOrigin { 
        case auto
        case explicitTap 
    }

    init(containerView: UIView) {
        self.containerView = containerView
    }

    func showSuggestion(text: String, tone: ToneStatus, origin: SuggestionOrigin = .auto) {
        #if DEBUG
        KBDLog("📨 ChipManager.showSuggestion origin=\(origin) requireExplicitTap=\(requireExplicitTap)", .debug, "ChipManager")
        KBDLog("📨 ChipManager: showSuggestion called with text: '\(text)', tone: \(tone)", .debug, "ChipManager")
        #endif
        
        // Block autos when user closed a chip, until next explicit tap
        if requireExplicitTap && origin == .auto {
            #if DEBUG
            KBDLog("🚫 ChipManager: auto blocked (awaiting explicit tap)", .debug, "ChipManager")
            #endif
            return
        }

        // If this came from an explicit tap, clear the gate
        if origin == .explicitTap { 
            requireExplicitTap = false 
            #if DEBUG
            KBDLog("🔓 ChipManager: explicit tap - clearing gate", .debug, "ChipManager")
            #endif
        }
        
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
        chip.onTimeout = { [weak self, weak chip] in
            guard let self, let chip else { return }
            #if DEBUG
            KBDLog("⏰ ChipManager: Clearing active chip reference (timeout)", .debug, "ChipManager")
            #endif
            // ⏱️ Also pause autos after timeout so we don't nag; explicit tap re-enables
            self.requireExplicitTap = true
            if self.activeChip === chip { self.activeChip = nil }
            // Disarm so the next suggestion needs a tap again
            (containerView as? KeyboardController)?.suggestionsArmed = false
        }

        containerView.addSubview(chip) // layout first
        
        // Remove any old position constraints if you decide to store them.
        // Position chip - overlay spelling bar if available, fallback to bottom of keyboard
        if let bar = suggestionBar {
            // Overlay the chip exactly on top of the spelling bar
            NSLayoutConstraint.activate([
                chip.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                chip.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                chip.topAnchor.constraint(equalTo: bar.topAnchor),
                chip.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
            ])

            // Make sure it visually sits above the bar
            chip.layer.zPosition = bar.layer.zPosition + 1
            containerView.bringSubviewToFront(chip)

            // While chip is visible, prevent taps from reaching the bar
            let oldBarUserInteraction = bar.isUserInteractionEnabled
            bar.isUserInteractionEnabled = false

            // Re-enable bar interaction when chip goes away
            chip.onDismissed = { [weak self, weak chip, weak bar] in
                guard let self, let chip else { return }
                bar?.isUserInteractionEnabled = oldBarUserInteraction
                KBDLog("🏁 ChipManager: Chip fully dismissed, clearing reference", .debug, "ChipManager")
                if self.activeChip === chip { self.activeChip = nil }
            }
            chip.onDismiss = { [weak self, weak chip, weak bar] in
                guard let self, let chip else { return }
                bar?.isUserInteractionEnabled = oldBarUserInteraction
                self.delegate?.suggestionChipDidDismiss(chip)
                // ✅ User explicitly closed a suggestion: require explicit tap to show next ones
                self.requireExplicitTap = true
                if self.activeChip === chip { 
                    #if DEBUG
                    KBDLog("🗑️ ChipManager: Clearing active chip reference (user dismissed)", .debug, "ChipManager")
                    #endif
                    self.activeChip = nil 
                }
            }
        } else {
            // Fallback for when there is no bar: pin to bottom of keyboard view
            NSLayoutConstraint.activate([
                chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                chip.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12)
            ])
            containerView.bringSubviewToFront(chip)
            
            // Handle dismiss for fallback case too
            chip.onDismissed = { [weak self, weak chip] in
                guard let self, let chip else { return }
                KBDLog("🏁 ChipManager: Chip fully dismissed, clearing reference", .debug, "ChipManager")
                if self.activeChip === chip { self.activeChip = nil }
            }
            chip.onDismiss = { [weak self, weak chip] in
                guard let self, let chip else { return }
                self.delegate?.suggestionChipDidDismiss(chip)
                // ✅ User explicitly closed a suggestion: require explicit tap to show next ones
                self.requireExplicitTap = true
                if self.activeChip === chip { 
                    #if DEBUG
                    KBDLog("🗑️ ChipManager: Clearing active chip reference (user dismissed)", .debug, "ChipManager")
                    #endif
                    self.activeChip = nil 
                }
            }
        }
        
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
    
    // MARK: - Convenience Methods for Origin-based Suggestions
    
    func showAutoSuggestion(text: String, toneString: String) {
        showSuggestion(text: text, tone: ToneStatus(from: toneString), origin: .auto)
    }

    func showButtonSuggestion(text: String, toneString: String) {
        showSuggestion(text: text, tone: ToneStatus(from: toneString), origin: .explicitTap)
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
