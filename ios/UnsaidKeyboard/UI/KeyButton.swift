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
        // For letter keys: Let UIStackView .fillEqually distribution control width
        // Only enforce minimum height for touch targets
        return CGSize(
            width: original.width,  // Use natural width, let stack distribution control final width
            height: max(KeyButtonFactory.touchTargetHeight, original.height) // 44–46
        )
    }
    
    // MARK: - Precision Hit Testing (44×44 Tap Target Guarantee)
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Guarantee 44×44 tap target by expanding touch area instead of visual width
        let minW: CGFloat = 44
        let minH: CGFloat = KeyButtonFactory.touchTargetHeight
        let dx = max(0, (minW - bounds.width) / 2)
        let dy = max(0, (minH - bounds.height) / 2)
        let expanded = bounds.insetBy(dx: -dx, dy: -dy)
        return expanded.contains(point)
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
