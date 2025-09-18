//
//  LayoutUtilities.swift
//  UnsaidKeyboard
//
//  Utilities for preventing zero-size layouts and ensuring valid dimensions
//

import Foundation
#if canImport(UIKit)
import UIKit

// MARK: - Size Guards

/// Ensures a value is non-zero and finite, returning a minimum fallback if needed
func nonZero(_ v: CGFloat, min: CGFloat = 1) -> CGFloat {
    guard v.isFinite else { return min }
    return max(min, v)
}

/// Ensures a CGSize has non-zero dimensions
func nonZeroSize(_ size: CGSize, minWidth: CGFloat = 1, minHeight: CGFloat = 1) -> CGSize {
    return CGSize(
        width: nonZero(size.width, min: minWidth),
        height: nonZero(size.height, min: minHeight)
    )
}

/// Ensures a CGRect has non-zero dimensions
func nonZeroRect(_ rect: CGRect, minWidth: CGFloat = 1, minHeight: CGFloat = 1) -> CGRect {
    return CGRect(
        x: rect.origin.x,
        y: rect.origin.y,
        width: nonZero(rect.size.width, min: minWidth),
        height: nonZero(rect.size.height, min: minHeight)
    )
}

// MARK: - Color Utilities

/// Clamps a value to the 0-1 range for UIColor components
func clamp01(_ x: CGFloat) -> CGFloat {
    return max(0, min(1, x))
}

extension UIColor {
    /// Convenience initializer for RGB values in 0-255 range
    convenience init(rgb r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha a: CGFloat = 1) {
        self.init(red: r/255, green: g/255, blue: b/255, alpha: a)
    }
    
    /// Convenience initializer with clamped 0-1 values
    convenience init(clamped red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.init(red: clamp01(red), green: clamp01(green), blue: clamp01(blue), alpha: clamp01(alpha))
    }
}

// MARK: - Layout Helpers

extension NSLayoutConstraint {
    /// Creates a width constraint with minimum value protection
    static func safeWidth(for view: UIView, equalTo constant: CGFloat, priority: UILayoutPriority = .required) -> NSLayoutConstraint {
        let constraint = view.widthAnchor.constraint(equalToConstant: nonZero(constant))
        constraint.priority = priority
        return constraint
    }
    
    /// Creates a height constraint with minimum value protection
    static func safeHeight(for view: UIView, equalTo constant: CGFloat, priority: UILayoutPriority = .required) -> NSLayoutConstraint {
        let constraint = view.heightAnchor.constraint(equalToConstant: nonZero(constant))
        constraint.priority = priority
        return constraint
    }
}

#endif