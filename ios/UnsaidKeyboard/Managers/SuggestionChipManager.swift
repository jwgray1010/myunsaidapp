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
        guard let containerView = containerView else { return }

        // ✅ COALESCE DUPLICATES: Don't re-show the same chip, just refresh tone styling
        if let active = activeChip, active.getCurrentSuggestion() == text {
            // Optionally update tone color in-place instead of re-presenting
            active.presentSuggestion(text, tone: tone)  // just refresh styling
            return
        }

        // ✅ SEQUENCE ANIMATIONS: If there is an active chip, dismiss and present the new one after animation
        if let old = activeChip {
            old.onDismissed = { [weak self] in
                self?.presentNewChip(text: text, tone: tone, in: containerView)
            }
            old.dismiss(animated: true)
            activeChip = nil
            return
        }

        presentNewChip(text: text, tone: tone, in: containerView)
    }

    private func presentNewChip(text: String, tone: ToneStatus, in containerView: UIView) {
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
            self.activeChip = nil
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
        
        showSuggestion(text: text, tone: tone(from: toneString))
        
        // Mark tutorial as shown if this was a tutorial message
        if isTutorialMessage(text) {
            markTutorialAsShown()
        }
    }
    
    // ✅ CENTRALIZED TONE MAPPING: Single source of truth for string→ToneStatus conversion
    private func tone(from s: String) -> ToneStatus {
        switch s.lowercased() {
        case "alert": return .alert
        case "caution": return .caution
        case "clear": return .clear
        default: return .neutral
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
