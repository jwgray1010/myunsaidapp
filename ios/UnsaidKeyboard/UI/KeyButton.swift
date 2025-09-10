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
    
    // MARK: - Expanded Hit Area
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Expand hit area by 8pt horizontally, 4pt vertically for better touch experience
        let expandedBounds = bounds.insetBy(dx: -8, dy: -4)
        return expandedBounds.contains(point)
    }
    
    // MARK: - Performance Optimization
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Use shadow path for better performance
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        }
    }
    
    // MARK: - Touch Feedback
    
    override var isHighlighted: Bool {
        didSet {
            // Subtle press animation for tactile feedback
            let transform: CGAffineTransform = isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            let alpha: CGFloat = isHighlighted ? 0.92 : 1.0
            
            UIView.animate(withDuration: 0.08,
                           delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.transform = transform
                self.alpha = alpha
            }
        }
    }
}
