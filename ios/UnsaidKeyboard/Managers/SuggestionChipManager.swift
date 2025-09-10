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

        // Dismiss existing chip if any
        dismissCurrentChip()

        // Create new chip
        let chip = SuggestionChipView()
        chip.setPreview(text: text, tone: tone, textHash: String(text.hashValue))

        // Avoid retain cycles: the chip owns these closures
        chip.onExpanded = { [weak self, weak chip] in
            guard let self, let chip = chip else { return }
            self.delegate?.suggestionChipDidExpand(chip)
        }
        chip.onDismiss = { [weak self, weak chip] in
            guard let self, let chip = chip else { return }
            self.delegate?.suggestionChipDidDismiss(chip)
            // Note: chip dismisses itself, no need for extra dismissCurrentChip() call
            self.activeChip = nil
        }

        containerView.addSubview(chip)
        activeChip = chip

        // Position chip - prefer under suggestion bar, fallback to bottom
        if let bar = suggestionBar {
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
                chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8)
            ])
        } else {
            // Fallback to bottom positioning with larger inset for home indicator
            NSLayoutConstraint.activate([
                chip.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                chip.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
            ])
        }

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
        
        let tone: ToneStatus
        switch toneString.lowercased() {
        case "alert": tone = .alert
        case "caution": tone = .caution
        case "clear": tone = .clear
        default: tone = .neutral
        }
        showSuggestion(text: text, tone: tone)
        
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

    func configure(suggestionBar: UIView, toneButton: UIButton) {
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
