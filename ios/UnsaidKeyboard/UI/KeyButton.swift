//
//  KeyButton.swift
//  UnsaidKeyboard
//
//  UIButton subclass with guaranteed iOS-compliant touch targets and expanded hit areas
//

import UIKit

/// UIButton subclass that ensures iOS compliance with 44×44pt minimum tap targets
final class KeyButton: UIButton {
    
    // MARK: - Touch Target Enforcement
    
    override var intrinsicContentSize: CGSize {
        let original = super.intrinsicContentSize
        // Ensure minimum 44×44pt for iOS accessibility compliance
        return CGSize(
            width: max(44, original.width),
            height: max(44, original.height)
        )
    }
    
    // MARK: - Precision Hit Testing (Performance Optimized)
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // First check: Is this within our actual bounds?
        guard bounds.contains(point) else { 
            // Second check: Allow minimal edge extension for thumb-friendly taps
            let edgeExtension: CGFloat = 2.0  // Reduced from 8pt to prevent overlaps
            let expandedBounds = bounds.insetBy(dx: -edgeExtension, dy: -1)
            return expandedBounds.contains(point)
        }
        return true  // Inside our real bounds = always accept
    }
    
    // MARK: - Performance Optimization
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Use shadow path for better performance
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        }
    }
    
    // MARK: - Touch Feedback (Performance Optimized)
    
    override var isHighlighted: Bool {
        didSet {
            // Performance: Disable rasterization during animation to prevent hitches
            if isHighlighted != oldValue {
                layer.shouldRasterize = false
            }
            
            // Subtle press animation for tactile feedback
            let transform: CGAffineTransform = isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            let alpha: CGFloat = isHighlighted ? 0.92 : 1.0
            
            UIView.animate(withDuration: 0.08,
                           delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.transform = transform
                self.alpha = alpha
            } completion: { finished in
                // Re-enable rasterization after animation completes for memory efficiency
                if finished && !self.isHighlighted {
                    self.layer.shouldRasterize = true
                    self.layer.rasterizationScale = UIScreen.main.scale
                }
            }
        }
    }
}
