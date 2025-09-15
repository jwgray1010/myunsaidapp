//
//  SuggestionChipManager.swift
//  UnsaidKeyboard
//
//  Manages suggestion chips display and interaction
//

import UIKit
import Foundation

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
        print("📨 ChipManager: showSuggestion called with text: '\(text)', tone: \(tone)")
        #endif
        
        guard let containerView = containerView else { return }

        // ✅ DEFENSIVE COALESCING: Only coalesce if the chip is actually visible on screen
        if let active = activeChip {
            let isOnscreen = (active.superview != nil) && (active.window != nil) && (active.alpha > 0.01)
            let isSameText = active.getCurrentSuggestion() == text
            
            #if DEBUG
            print("🔍 ChipManager: Active chip found - onscreen: \(isOnscreen), sameText: \(isSameText), text: '\(text)'")
            #endif
            
            if isSameText && isOnscreen {
                // Chip is visible and has same text - just refresh styling
                #if DEBUG
                print("🔄 ChipManager: Refreshing existing chip")
                #endif
                active.presentSuggestion(text, tone: tone)
                return
            } else if isSameText && !isOnscreen {
                // Chip has same text but is off-screen - clean up and create new one
                #if DEBUG
                print("🧹 ChipManager: Cleaning up off-screen chip")
                #endif
                activeChip = nil
                // Fall through to create new chip
            } else if !isSameText {
                // Different text - dismiss old chip and create new one
                #if DEBUG
                print("🔄 ChipManager: Dismissing old chip for new text")
                #endif
                active.onDismissed = { [weak self] in
                    self?.presentNewChip(text: text, tone: tone, in: containerView)
                }
                active.dismiss(animated: true)
                activeChip = nil
                return
            }
        }

        // Create new chip
        #if DEBUG
        print("🆕 ChipManager: Creating new chip for text: '\(text)'")
        #endif
        presentNewChip(text: text, tone: tone, in: containerView)
    }

    private func presentNewChip(text: String, tone: ToneStatus, in containerView: UIView) {
        #if DEBUG
        print("🎯 ChipManager: Presenting new chip, clearing any existing active chip")
        #endif
        
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
                print("🗑️ ChipManager: Clearing active chip reference (user dismissed)")
                #endif
                self.activeChip = nil 
            }
        }
        chip.onTimeout = { [weak self, weak chip] in
            guard let self, let chip else { return }
            #if DEBUG
            print("⏰ ChipManager: Clearing active chip reference (timeout)")
            #endif
            if self.activeChip === chip { self.activeChip = nil }
        }
        chip.onDismissed = { [weak self, weak chip] in
            guard let self, let chip else { return }
            #if DEBUG
            print("🏁 ChipManager: Chip fully dismissed, clearing reference")
            #endif
            if self.activeChip === chip { self.activeChip = nil }
        }

        containerView.addSubview(chip) // layout first
        
        // Position chip - prefer under suggestion bar, fallback to bottom
        if let bar = suggestionBar {
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
                chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8)
            ])
        } else {
            NSLayoutConstraint.activate([
                chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                chip.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
            ])
        }
        
        activeChip = chip
        #if DEBUG
        print("✅ ChipManager: Set new active chip")
        #endif
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
    
    // MARK: - First-time User Management
    
    private func markTutorialAsShown() {
    // AppGroups.shared already returns a valid UserDefaults (falls back to .standard internally)
    AppGroups.shared.set(true, forKey: Self.tutorialShownKey)
    }
    
    private func shouldShowTutorial() -> Bool {
    return !AppGroups.shared.bool(forKey: Self.tutorialShownKey)
    }
}
