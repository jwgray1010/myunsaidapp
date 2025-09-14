//
//  KeyButtonFactory.swift
//  UnsaidKeyboard
//
//  Factory for creating and styling keyboard buttons (iOS-like, tuned spacing)
//  Enhancements:
//  - 44×44pt minimum tap targets (HIG compliant) with expanded hit areas
//  - Dynamic Type (letter + control keys) with graceful downscaling
//  - Accessibility-aware visuals (Reduce Motion / Darker System Colors)
//  - Performance: shadowPath + conditional rasterization on “important” keys only
//  - Consistent styling helpers & brand color hooks
//

import UIKit

// MARK: - KeyButton
/// UIButton subclass that enforces a minimum 44×44pt touch target and provides
/// fast, interruptible press feedback without layout thrash.
final class KeyButton: UIButton {

    // Ensure minimum HIG target while letting Auto Layout compress if needed
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: max(44, s.width), height: max(44, s.height))
    }

    // Expanded hit area for comfort
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -4).contains(point)
    }

    // Cheap shadows: keep a path so CoreAnimation doesn’t re-raster on each frame
    override func layoutSubviews() {
        super.layoutSubviews()
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        }
    }

    // Snappy, interruptible press cue
    override var isHighlighted: Bool {
        didSet {
            let t = isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            let a: CGFloat = isHighlighted ? 0.92 : 1.0
            UIView.animate(withDuration: 0.08,
                           delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.transform = t
                self.alpha = a
            }
        }
    }
}

// MARK: - Factory
final class KeyButtonFactory {

    // MARK: Sizing
    /// Enforce at least 44pt (HIG). Nudge larger on Plus/Max for comfort.
    static var touchTargetHeight: CGFloat {
        let w = UIScreen.main.bounds.width
        if w >= 414 { return 46 }         // Plus/Max
        if w <= 320 { return 44 }         // SE/Mini
        return 44
    }

    static let minKeyWidth: CGFloat = 26
    static let keyCornerRadius: CGFloat = 8

    // MARK: Creation

    static func makeKeyButton(title: String) -> KeyButton {
        let b = KeyButton(type: .system)
        commonKeySetup(b, hPad: 4, vPad: 8) // compact horizontal padding = better fit
        b.setTitle(title, for: .normal)

        // Dynamic Type + graceful downscaling for tight layouts
        let base = UIFont.systemFont(ofSize: 20, weight: .semibold)
        b.titleLabel?.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: base)
        b.titleLabel?.adjustsFontForContentSizeCategory = true
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.80
        b.titleLabel?.numberOfLines = 1
        b.titleLabel?.textAlignment = .center

        applyLetterKeyStyle(to: b)
        return b
    }

    static func makeControlButton(title: String,
                                  background: UIColor = .systemGray4,
                                  text: UIColor = .label) -> UIButton {
        let b = ExtendedTouchButton(type: .system)
        commonKeySetup(b, hPad: 6, vPad: 4)
        b.setTitle(title, for: .normal)
        b.accessibilityLabel = title

        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.titleLabel?.adjustsFontForContentSizeCategory = false
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.90
        b.setContentCompressionResistancePriority(.required, for: .horizontal)

        applySpecialKeyStyle(to: b, background: background, text: text)
        return b
    }

    static func makeSpaceButton() -> UIButton {
        let b = ExtendedSpaceButton(type: .system)
        commonKeySetup(b, hPad: 6, vPad: 4)
        b.setTitle("space", for: .normal)
        b.accessibilityLabel = "Space"
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.titleLabel?.adjustsFontForContentSizeCategory = false
        applySpecialKeyStyle(to: b, background: .systemGray4, text: .label)
        return b
    }

    static func makeDeleteButton() -> KeyButton {
        let b = KeyButton(type: .system)
        commonKeySetup(b, hPad: 8, vPad: 10)
        b.setImage(UIImage(systemName: "delete.left"), for: .normal)
        b.tintColor = .label
        let cfg = UIImage.SymbolConfiguration(textStyle: .title2, scale: .medium)
        b.setPreferredSymbolConfiguration(cfg, forImageIn: .normal)
        applyImportantKeyStyle(to: b, background: .white, text: .label)
        return b
    }

    static func makeShiftButton(useSymbol: Bool = false) -> UIButton {
        let b = ExtendedTouchButton(type: .system)
        commonKeySetup(b, hPad: 6, vPad: 4)
        if useSymbol, let img = UIImage(systemName: "shift") {
            b.setImage(img, for: .normal)
            b.tintColor = .label
        } else {
            b.setTitle("⇧", for: .normal)
        }
        b.accessibilityLabel = "Shift"
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.titleLabel?.adjustsFontForContentSizeCategory = false
        applySpecialKeyStyle(to: b, background: .systemGray4, text: .label)
        return b
    }

    static func makeReturnButton() -> KeyButton {
        let b = KeyButton(type: .system)
        commonKeySetup(b, hPad: 8, vPad: 10)
        b.setTitle("Return", for: .normal)
        b.accessibilityLabel = "Return"

        let base = UIFont.systemFont(ofSize: 18, weight: .medium)
        b.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        b.titleLabel?.adjustsFontForContentSizeCategory = true

        // Give “Return” a bit more visual weight
        applyImportantKeyStyle(to: b, background: .systemGray3, text: .label)
        return b
    }

    /// Branded “Secure” action key (compact width to avoid crowding near Return).
    static func makeSecureButton() -> KeyButton {
        let b = KeyButton(type: .system)
        commonKeySetup(b, hPad: 6, vPad: 10)
        b.setTitle("Secure", for: .normal)
        b.accessibilityLabel = "Secure"

        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)

        let base = UIFont.systemFont(ofSize: 16, weight: .medium)
        b.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        b.titleLabel?.adjustsFontForContentSizeCategory = true

        applyBrandKeyStyle(to: b, brandBackground: .keyboardRose)
        return b
    }

    // MARK: Styling

    private static func commonKeySetup(_ button: UIButton, hPad: CGFloat, vPad: CGFloat) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: touchTargetHeight).isActive = true
        if hPad > 4 { // control/utility keys only
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: minKeyWidth).isActive = true
        }
        button.contentEdgeInsets = UIEdgeInsets(top: vPad, left: hPad, bottom: vPad, right: hPad)
        button.clipsToBounds = false

        // Accessibility
        button.accessibilityTraits = .button
        button.isAccessibilityElement = true

        if #available(iOS 13.4, *) {
            button.isPointerInteractionEnabled = false
        }
    }

    private static func applyLetterKeyStyle(to button: UIButton) {
        button.backgroundColor = .systemBackground
        setContentColor(button, .label)
        decorateStandard(button)
    }

    private static func applySpecialKeyStyle(to button: UIButton, background: UIColor, text: UIColor) {
        button.backgroundColor = background
        setContentColor(button, text)
        decorateStandard(button)
    }

    private static func applyImportantKeyStyle(to button: UIButton, background: UIColor, text: UIColor) {
        button.backgroundColor = background
        setContentColor(button, text)
        decorateWithShadow(button)
    }

    private static func applyBrandKeyStyle(to button: UIButton, brandBackground: UIColor) {
        button.backgroundColor = brandBackground
        setContentColor(button, .readableText(on: brandBackground))
        decorateWithShadow(button)
    }

    // Standard keys = no shadow (GPU-cheap)
    private static func decorateStandard(_ button: UIButton) {
        button.layer.cornerRadius = keyCornerRadius
        button.layer.borderWidth = UIAccessibility.isDarkerSystemColorsEnabled ? 0.75 : 0.5
        button.layer.borderColor = UIColor.keyBorder.cgColor
        // No shadow to keep compositing cheap
        button.layer.shadowOpacity = 0
        button.layer.shouldRasterize = false
    }

    // Important keys get a subtle shadow + rasterization for performance
    private static func decorateWithShadow(_ button: UIButton) {
        button.layer.cornerRadius = keyCornerRadius
        button.layer.borderWidth = UIAccessibility.isDarkerSystemColorsEnabled ? 0.75 : 0.5
        button.layer.borderColor = UIColor.keyBorder.cgColor
        button.layer.shadowColor = UIColor.keyShadow.cgColor
        button.layer.shadowOpacity = ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.0 : 0.14
        button.layer.shadowRadius  = 1.0
        button.layer.shadowOffset  = CGSize(width: 0, height: 1)
        button.layer.shouldRasterize = button.layer.shadowOpacity > 0
        button.layer.rasterizationScale = UIScreen.main.scale
    }

    private static func setContentColor(_ button: UIButton, _ color: UIColor) {
        button.setTitleColor(color, for: .normal)
        button.tintColor = color
        if let img = button.image(for: .normal) {
            button.setImage(img.withRenderingMode(.alwaysTemplate), for: .normal)
        }
    }

    // MARK: State Updates

    static func updateShiftButtonAppearance(_ button: UIButton, isShifted: Bool, isCapsLocked: Bool) {
        if isCapsLocked {
            let bg = UIColor.keyboardRose
            button.backgroundColor = bg
            setContentColor(button, .readableText(on: bg))
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

    // MARK: Animations

    /// Branded press for “Secure” (slightly deeper dip)
    static func animateSecureFixPress(_ button: UIButton) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduceMotion ? 0 : 0.06, animations: {
            button.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
            button.alpha = 0.90
            if let base = button.backgroundColor {
                button.backgroundColor = base.mixed(with: .black, amount: 0.06)
            }
        }) { _ in
            UIView.animate(withDuration: reduceMotion ? 0 : 0.10) {
                button.transform = .identity
                button.alpha = 1.0
                button.backgroundColor = .keyboardRose
            }
        }
    }

    /// Standard letter key press
    static func animateButtonPress(_ button: UIButton) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduceMotion ? 0 : 0.08, animations: {
            button.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            button.alpha = 0.92
        }) { _ in
            UIView.animate(withDuration: reduceMotion ? 0 : 0.08) {
                button.transform = .identity
                button.alpha = 1.0
            }
        }
    }

    /// Shift/Delete/etc.
    static func animateSpecialButtonPress(_ button: UIButton) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reduceMotion ? 0 : 0.08, animations: {
            button.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
            button.alpha = 0.88
        }) { _ in
            UIView.animate(withDuration: reduceMotion ? 0 : 0.08) {
                button.transform = .identity
                button.alpha = 1.0
            }
        }
    }
}

// MARK: - Extended Buttons

/// Space bar: even larger hit area + cheap shadow path
final class ExtendedSpaceButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -8).contains(point)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
    override var isHighlighted: Bool {
        didSet {
            let t = isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            let a: CGFloat = isHighlighted ? 0.85 : 1.0
            UIView.animate(withDuration: 0.08,
                           delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.transform = t
                self.alpha = a
            }
        }
    }
}

/// Control keys: larger hit area + cheap shadow path
final class ExtendedTouchButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -4).contains(point)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
    override var isHighlighted: Bool {
        didSet {
            let t = isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            let a: CGFloat = isHighlighted ? 0.92 : 1.0
            UIView.animate(withDuration: 0.08,
                           delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.transform = t
                self.alpha = a
            }
        }
    }
}

// MARK: - Colors
extension UIColor {

    /// Background for the whole keyboard
    static var keyboardBackground: UIColor {
        UIColor(red: 240/255, green: 243/255, blue: 255/255, alpha: 1.0)
    }

    /// Brand rose from logo (dynamic dark tweak)
    static var keyboardRose: UIColor {
        if #available(iOS 13.0, *) {
            return UIColor { trait in
                let base = UIColor(red: 233/255, green: 30/255, blue: 99/255, alpha: 1.0) // #E91E63
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

    /// Contrast-aware text color (black/white) based on background luminance
    static func readableText(on background: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard background.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        let lum = 0.2126 * pow(r, 2.2) + 0.7152 * pow(g, 2.2) + 0.0722 * pow(b, 2.2)
        return lum > 0.5 ? .black : .white
    }

    /// Simple blend (used for pressed state darkening)
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        let t = max(0, min(1, amount))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t,
                       green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t,
                       alpha: a1 + (a2 - a1) * t)
    }
}
