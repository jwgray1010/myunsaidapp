///
//  KeyButtonFactory.swift
//  UnsaidKeyboard
//
//  Factory for creating and styling keyboard buttons (iOS-like, tuned spacing)
//

import UIKit

// MARK: - KeyButton Class
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

final class KeyButtonFactory {

    // MARK: - Layout constants
    // iOS-compliant keyboard sizing (enforces 44pt minimum per Apple HIG)
    static var touchTargetHeight: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        if screenWidth >= 414 { // Plus/Max devices
            return 46
        } else if screenWidth <= 320 { // SE/Mini devices  
            return 44 // iOS minimum - was 38, now compliant
        } else {
            return 44 // iOS minimum - was 42, now compliant
        }
    }
    
    static let minKeyWidth: CGFloat = 26  // Reduced to match iOS letter key proportions
    static let keyCornerRadius: CGFloat = 8 // Increased for modern iOS look

    // MARK: - Button Creation

    static func makeKeyButton(title: String) -> KeyButton {
        let button = KeyButton(type: .system)
        commonKeySetup(button, hPad: 4, vPad: 8) // Reduced horizontal padding for better iOS fit
        button.setTitle(title, for: .normal)

        // Use iOS-like sizing with Dynamic Type support - slightly smaller for better fit
        let baseFont = UIFont.systemFont(ofSize: 20, weight: .semibold) // Reduced from 23 to 20
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: baseFont)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8 // Allow more scaling down
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.textAlignment = .center

        applyLetterKeyStyle(to: button)
        return button
    }

    static func makeControlButton(title: String,
                                  background: UIColor = .systemGray4,
                                  text: UIColor = .label) -> UIButton {
        let button = ExtendedTouchButton(type: .system)
        commonKeySetup(button, hPad: 6, vPad: 4)
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = title

        // Match letter-key height; slightly smaller weight reads well.
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        button.titleLabel?.minimumScaleFactor = 0.9
        button.titleLabel?.adjustsFontSizeToFitWidth = true

        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        applySpecialKeyStyle(to: button, background: background, text: text)
        return button
    }

    static func makeSpaceButton() -> UIButton {
        let button = ExtendedSpaceButton(type: .system) // Use special subclass for better touch
        commonKeySetup(button, hPad: 6, vPad: 4)
        button.setTitle("space", for: .normal)
        button.accessibilityLabel = "Space"
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        applySpecialKeyStyle(to: button, background: .systemGray4, text: .label)
        return button
    }

    static func makeDeleteButton() -> KeyButton {
        let button = KeyButton(type: .system)
        commonKeySetup(button, hPad: 8, vPad: 10)

        button.setImage(UIImage(systemName: "delete.left"), for: .normal)
        button.tintColor = UIColor.label

        let config = UIImage.SymbolConfiguration(textStyle: .title2, scale: .medium)
        button.setPreferredSymbolConfiguration(config, forImageIn: .normal)

        applyImportantKeyStyle(to: button, background: .white, text: .label)
        return button
    }

    static func makeShiftButton(useSymbol: Bool = false) -> UIButton {
        let button = ExtendedTouchButton(type: .system)
        commonKeySetup(button, hPad: 6, vPad: 4)
        if useSymbol, let img = UIImage(systemName: "shift") {
            button.setImage(img, for: .normal)
            button.tintColor = .label
        } else {
            button.setTitle("⇧", for: .normal)
        }
        button.accessibilityLabel = "Shift"
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        applySpecialKeyStyle(to: button, background: .systemGray4, text: .label)
        return button
    }

    static func makeReturnButton() -> KeyButton {
        let button = KeyButton(type: .system)
        commonKeySetup(button, hPad: 8, vPad: 10)
        button.setTitle("Return", for: .normal)
        button.accessibilityLabel = "Return"

        let baseFont = UIFont.systemFont(ofSize: 18, weight: .medium)
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        button.titleLabel?.adjustsFontForContentSizeCategory = true

        // Use important key styling for Return button (gets shadow for prominence)
        applyImportantKeyStyle(to: button, background: .systemGray3, text: .label)

        return button
    }

    /// Branded Secure action key (smaller to fit better).
    static func makeSecureButton() -> KeyButton {
        let button = KeyButton(type: .system)
        commonKeySetup(button, hPad: 6, vPad: 10) // Reduced horizontal padding from 8 to 6
        
        // Shorter title so it fits naturally
        button.setTitle("Secure", for: .normal)
        button.accessibilityLabel = "Secure"
        
        // Match Return's control-key sizing behavior
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Slightly smaller font to fit better
        let baseFont = UIFont.systemFont(ofSize: 16, weight: .medium) // Reduced from 18 to 16
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        
        // Brand rose background + white text for best contrast
        button.backgroundColor = .keyboardRose
        button.setTitleColor(.white, for: .normal)
        
        button.layer.cornerRadius = keyCornerRadius
        button.layer.borderWidth = 0
        
        return button
    }

    // MARK: - Styling

    private static func commonKeySetup(_ button: UIButton, hPad: CGFloat, vPad: CGFloat) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: touchTargetHeight).isActive = true
        // Remove minimum width constraint for letter keys to allow natural iOS proportions
        if hPad > 4 { // Only apply min width to control buttons (which have larger padding)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: minKeyWidth).isActive = true
        }
        button.contentEdgeInsets = UIEdgeInsets(top: vPad, left: hPad, bottom: vPad, right: hPad)
        button.clipsToBounds = false

        // Improved accessibility
        button.accessibilityTraits = .button
        button.isAccessibilityElement = true

        if #available(iOS 13.4, *) {
            button.isPointerInteractionEnabled = false
        }
    }

    /// Unified styling for consistent keyboard appearance
    private struct KeyStyle {
        static func apply(to button: UIButton) {
            button.backgroundColor = UIColor.white
            button.setTitleColor(UIColor.label, for: .normal)
            button.layer.cornerRadius = keyCornerRadius
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.systemGray4.cgColor
            
            // Shadow for depth
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOffset = CGSize(width: 0, height: 1)
            button.layer.shadowOpacity = 0.1
            button.layer.shadowRadius = 2
        }
    }

    private static func applyLetterKeyStyle(to button: UIButton) {
        button.backgroundColor = .systemBackground
        button.setTitleColor(.label, for: .normal)
        decorate(button)
    }

    private static func applySpecialKeyStyle(to button: UIButton, background: UIColor, text: UIColor) {
        button.backgroundColor = background
        setContentColor(button, text)
        decorate(button)
    }
    
    private static func applyImportantKeyStyle(to button: UIButton, background: UIColor, text: UIColor) {
        button.backgroundColor = background
        setContentColor(button, text)
        decorateWithShadow(button) // Important keys get shadows for visual hierarchy
    }

    private static func applyBrandKeyStyle(to button: UIButton, brandBackground: UIColor) {
        button.backgroundColor = brandBackground
        button.setTitleColor(.white, for: .normal) // white text for best contrast
        button.tintColor = .white
        decorateWithShadow(button) // Brand keys get shadows for prominence
    }

    private static func decorate(_ button: UIButton) {
        button.layer.cornerRadius = keyCornerRadius
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.keyBorder.cgColor
        // Shadow removed for standard keys to improve GPU performance
        // Shadows only applied to special keys (delete, return, space) in their specific styling
    }
    
    private static func decorateWithShadow(_ button: UIButton) {
        button.layer.cornerRadius = keyCornerRadius
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.keyBorder.cgColor
        button.layer.shadowColor = UIColor.keyShadow.cgColor
        button.layer.shadowOpacity = 0.14
        button.layer.shadowRadius = 1.0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        // Ensure opaque background for better compositing
        button.layer.isOpaque = true
    }

    private static func setContentColor(_ button: UIButton, _ color: UIColor) {
        button.setTitleColor(color, for: .normal)
        button.tintColor = color
        if let image = button.image(for: .normal) {
            button.setImage(image.withRenderingMode(.alwaysTemplate), for: .normal)
        }
    }

    // MARK: - State Updates

    static func updateShiftButtonAppearance(_ button: UIButton, isShifted: Bool, isCapsLocked: Bool) {
        if isCapsLocked {
            // Caps lock ON -> brand rose background, readable text color on it
            let bg = UIColor.keyboardRose
            button.backgroundColor = bg
            setContentColor(button, UIColor.readableText(on: bg))
        } else if isShifted {
            button.backgroundColor = .systemGray3
            setContentColor(button, .label)
        } else {
            button.backgroundColor = .systemGray4
            setContentColor(button, .label)
        }
    }

    static func updateReturnButtonAppearance(_ button: UIButton, for type: UIReturnKeyType) {
        let label: String
        switch type {
        case .go: label = "Go"
        case .google: label = "Google"
        case .join: label = "Join"
        case .next: label = "Next"
        case .route: label = "Route"
        case .search: label = "Search"
        case .send: label = "Send"
        case .yahoo: label = "Yahoo"
        case .done: label = "Done"
        case .continue: label = "Continue"
        case .emergencyCall: label = "Emergency"
        case .default: label = "Return"
        @unknown default: label = "Return"
        }
        button.setTitle(label, for: .normal)
        button.accessibilityLabel = label
    }

    // MARK: - Animations

    /// Branded press for SecureFix (slightly deeper + alpha dip)
    static func animateSecureFixPress(_ button: UIButton) {
        UIView.animate(withDuration: 0.06, animations: {
            button.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            button.alpha = 0.90
            if let base = button.backgroundColor {
                button.backgroundColor = base.mixed(with: .black, amount: 0.06)
            }
        }) { _ in
            UIView.animate(withDuration: 0.10) {
                button.transform = .identity
                button.alpha = 1.0
                // restore to base rose
                button.backgroundColor = .keyboardRose
            }
        }
    }

    /// Standard animation for regular buttons
    static func animateButtonPress(_ button: UIButton) {
        UIView.animate(withDuration: 0.08, animations: {
            button.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            button.alpha = 0.92
        }) { _ in
            UIView.animate(withDuration: 0.08) {
                button.transform = .identity
                button.alpha = 1.0
            }
        }
    }

    /// Animation for special buttons (shift, delete, etc.)
    static func animateSpecialButtonPress(_ button: UIButton) {
        UIView.animate(withDuration: 0.08, animations: {
            button.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
            button.alpha = 0.88
        }) { _ in
            UIView.animate(withDuration: 0.08) {
                button.transform = .identity
                button.alpha = 1.0
            }
        }
    }
}

// MARK: - ExtendedSpaceButton
/// Special button for space bar with extra-large touch area for better UX
final class ExtendedSpaceButton: UIButton {

    // Extra large hit area for space bar - most commonly used key
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expandedBounds = bounds.insetBy(dx: -12, dy: -8) // Extra expansion for space
        return expandedBounds.contains(point)
    }

    // draw shadow efficiently
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    // lightweight press animation
    override var isHighlighted: Bool {
        didSet {
            let transform: CGAffineTransform = isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            let alpha: CGFloat = isHighlighted ? 0.85 : 1.0
            
            UIView.animate(withDuration: 0.08,
                           delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.transform = transform
                self.alpha = alpha
            }
        }
    }
}

// MARK: - ExtendedTouchButton
/// Enlarged hit area, fast press visuals, and a shadowPath for performance.
final class ExtendedTouchButton: UIButton {

    // bigger hit area
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expandedBounds = bounds.insetBy(dx: -8, dy: -4)
        return expandedBounds.contains(point)
    }

    // draw shadow efficiently
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    // lightweight press animation (no extra targets needed)
    override var isHighlighted: Bool {
        didSet {
            // Keep animations snappy and interruptible
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

// MARK: - UIColor Extensions
extension UIColor {
    // Background for the whole keyboard - subtle gradient feel
    static var keyboardBackground: UIColor { 
        UIColor(red: 240/255, green: 243/255, blue: 255/255, alpha: 1.0) // Very light blue tint
    }

    // === Brand Colors from beautiful icon ===
    // Pink color from unsaid_logo.png
    static var keyboardRose: UIColor {
        // Pink color to match the unsaid_logo.png
        if #available(iOS 13.0, *) {
            return UIColor { trait in
                let base = UIColor(red: 233/255, green: 30/255, blue: 99/255, alpha: 1.0) // #E91E63 - Vibrant Pink
                return trait.userInterfaceStyle == .dark
                ? base.mixed(with: .black, amount: 0.08)
                : base
            }
        } else {
            return UIColor(red: 233/255, green: 30/255, blue: 99/255, alpha: 1.0)
        }
    }

    static var keyBorder: UIColor { .systemGray3 }
    static var keyShadow: UIColor { .systemGray2 }

    // Rich purple from speech bubble for accent buttons
    static var brandRose: UIColor { 
        UIColor(red: 124/255, green: 58/255, blue: 237/255, alpha: 1.0) // #7C3AED - speech bubble purple
    }

    /// Choose readable text color (black/white) based on background luminance.
    static func readableText(on background: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        // WCAG relative luminance
        let lum = 0.2126 * pow(r, 2.2) + 0.7152 * pow(g, 2.2) + 0.0722 * pow(b, 2.2)
        // For the light rose, black yields better contrast than white
        return lum > 0.5 ? .black : .white
    }

    /// Blend two colors (used for pressed state darkening).
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        let t = max(0, min(1, amount))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t,
                       green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t,
                       alpha: a1 + (a2 - a1) * t)
    }
}
