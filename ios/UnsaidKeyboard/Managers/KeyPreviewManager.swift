//
//  KeyPreviewManager.swift
//  UnsaidKeyboard
//

import Foundation
import UIKit

// MARK: - Debug Extensions for Constraint Debugging

extension UIView {
    func debugConstraints() {
        #if DEBUG
        print("=== Debug Constraints for \(type(of: self)) ===")
        print("Frame: \(frame)")
        print("Bounds: \(bounds)")
        print("Constraints: \(constraints.count)")
        for constraint in constraints {
            print("  \(constraint)")
        }
        print("=== End Debug Constraints ===")
        #endif
    }
    
    // Helper to debug autolayout trace when constraint conflicts occur
    func debugAutolayoutTrace() {
        #if DEBUG
        print("🔍 Autolayout trace for \(type(of: self)):")
        print(self.value(forKey: "_autolayoutTrace") ?? "No trace available")
        #endif
    }
}

// MARK: - Constraint Conflict Debugging
// To use: In Xcode, add symbolic breakpoint for: UIViewAlertForUnsatisfiableConstraints
// Then in debugger console, run: po keyPreview.debugAutolayoutTrace()

@MainActor
final class KeyPreviewManager {

    private let keyPreviewTable = NSMapTable<UIButton, KeyPreview>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let autoDismissTimers = NSMapTable<UIButton, Timer>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    init() {}

    deinit {
        Task { @MainActor in
            dismissAllKeyPreviews()
        }
    }

    // MARK: - Public Interface

    func showKeyPreview(for button: UIButton) {
        // Only show for visible buttons with a visible single-character title
        guard button.window != nil,
              let title = button.title(for: .normal),
              !title.isEmpty,
              title.count == 1
        else { return }

        // Remove existing preview for this button
        hideKeyPreview(for: button)

        // Create new preview
        let preview = KeyPreview(text: title)
        keyPreviewTable.setObject(preview, forKey: button)

        // Find the keyboard's main container view (not a stack view)
        guard let containerView = findKeyboardContainerView(for: button) else { return }
        containerView.addSubview(preview)
        containerView.bringSubviewToFront(preview)

        // Keep above everything
        preview.layer.zPosition = 999

        // Constraints: centerX to key (flexible); bottom to key top (-8); keep on-screen
        let centerXConstraint = preview.centerXAnchor.constraint(equalTo: button.centerXAnchor)
        centerXConstraint.priority = .defaultHigh  // 750 - allows sliding when near edge
        
        let constraints = [
            centerXConstraint,
            preview.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -8),
            preview.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor, constant: 2),
            preview.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor, constant: 4),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -4),
            // Add width constraints to prevent crashes
            preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            preview.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, multiplier: 0.5)
        ]
        
        #if DEBUG
        print("📍 KeyPreview: Adding preview to \(type(of: containerView)) with frame: \(containerView.frame)")
        print("📍 KeyPreview: Button frame: \(button.frame)")
        #endif
        
        NSLayoutConstraint.activate(constraints)

        // Animate in with subtle pop effect
        preview.alpha = 0
        preview.transform = CGAffineTransform(scaleX: 0.86, y: 0.86) // start smaller
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            preview.alpha = 1
            preview.transform = CGAffineTransform(scaleX: 1.08, y: 1.08) // subtle pop
        } completion: { _ in
            UIView.animate(withDuration: 0.08) { 
                preview.transform = .identity 
            }
        }

        // Auto-dismiss
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.hideKeyPreview(for: button)
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDismissTimers.setObject(timer, forKey: button)
    }

    func hideKeyPreview(for button: UIButton) {
        if let timer = autoDismissTimers.object(forKey: button) {
            timer.invalidate()
            autoDismissTimers.removeObject(forKey: button)
        }

        guard let preview = keyPreviewTable.object(forKey: button) else { return }

        UIView.animate(withDuration: 0.08, delay: 0, options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction]) {
            preview.alpha = 0
            preview.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        } completion: { _ in
            preview.layer.removeAllAnimations()
            preview.removeFromSuperview()
        }

        keyPreviewTable.removeObject(forKey: button)
    }

    func dismissAllKeyPreviews() {
        let timerEnumerator = autoDismissTimers.objectEnumerator()
        while let timer = timerEnumerator?.nextObject() as? Timer {
            timer.invalidate()
        }
        autoDismissTimers.removeAllObjects()

        let enumerator = keyPreviewTable.objectEnumerator()
        while let preview = enumerator?.nextObject() as? KeyPreview {
            preview.layer.removeAllAnimations()
            preview.removeFromSuperview()
        }
        keyPreviewTable.removeAllObjects()
    }
    
    // MARK: - Private Helpers
    
    private func findKeyboardContainerView(for button: UIButton) -> UIView? {
        // Walk up the view hierarchy to find the KeyboardController root view
        var currentView: UIView? = button
        
        while let view = currentView {
            // Look specifically for KeyboardController view, not just any non-stack view
            if String(describing: type(of: view)).contains("KeyboardController") {
                return view
            }
            currentView = view.superview
        }
        
        // Fallback: find any view that's not a stack view and has reasonable bounds
        currentView = button.superview
        while let view = currentView {
            if !(view is UIStackView), view.bounds.width > 200 {
                return view
            }
            currentView = view.superview
        }
        
        // Last resort: use button's window or superview
        return button.window ?? button.superview
    }
}

// MARK: - Key Preview Balloon (adaptive size)

final class KeyPreview: UIView {
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        setupUI(text: text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(text: String) {
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false

        backgroundColor = .systemBackground
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 6
        layer.shadowOffset = .init(width: 0, height: 2)
        layer.masksToBounds = false

        label.text = text
        label.textColor = .label
        // Larger base font, scales with Dynamic Type
        let baseFont = UIFont.systemFont(ofSize: 28, weight: .semibold) // was 22
        label.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: baseFont)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(label)

        // Larger sizing with more padding for better visibility
        let minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        minHeightConstraint.priority = .defaultHigh  // 750, so it won't fight required constraints
        
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            minHeightConstraint,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }
}