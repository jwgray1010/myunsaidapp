//
//  SuggestionChipView.swift
//  UnsaidKeyboard
//
//  Lightweight, accessible suggestion “chip” with expand/collapse,
//  adaptive animations, and no “sparkles” icon in neutral state.
//

import UIKit

@MainActor
protocol SuggestionChipPresenting: AnyObject {
    func presentSuggestion(_ text: String, tone: ToneStatus)
    func dismissSuggestion()
}

@MainActor
final class SuggestionChipView: UIControl {

    // MARK: - UI
    private let capsule = UIView()
    private let iconView = UIImageView()
    private let textLabel = UILabel()
    private let chevronButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    // MARK: - Callbacks
    var onExpanded: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onTimeout: (() -> Void)?
    /// Optional hook when the chip animates in
    var onSurfaced: (() -> Void)?
    /// Optional hook when the chip finishes dismissal removal
    var onDismissed: (() -> Void)?

    // MARK: - State
    private var fullText: String = ""
    private var isExpanded = false
    private var autoHideTimer: Timer?
    private var textHash: String = ""
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // Layout
    private let collapsedHeight: CGFloat = 44
    private let compactVPad: CGFloat = 8
    private let expandedVPad: CGFloat = 12
    private let hPadCompact: CGFloat = 12
    private let hPadExpanded: CGFloat = 16

    private var compactConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []

    // Performance toggles
    private var enableShadows: Bool {
        // Prefer no heavy shadows when Low Power Mode is enabled
        !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    private var shouldAnimate: Bool {
        !UIAccessibility.isReduceMotionEnabled
    }

    // MARK: - Init / Deinit
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        autoHideTimer?.invalidate()
    }

    // MARK: - Public

    /// Sets the collapsed preview content and visual tone.
    /// Note: In **neutral** tone we intentionally hide the icon (no “sparkles”).
    func setPreview(text: String, tone: ToneStatus, textHash: String) {
        self.fullText = text
        self.textHash = textHash

        textLabel.text = text
        textLabel.numberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail
        applyTone(tone, animated: false)

        // Accessibility
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        accessibilityLabel = "Suggestion"
        accessibilityValue = text
        accessibilityHint = "Tap to expand"

        // Prepare haptics for near-term interaction
        haptic.prepare()
    }

    /// Sets the fully expanded content layout.
    func setExpanded(fullText: String) {
        textLabel.text = fullText
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        accessibilityValue = fullText
        accessibilityHint = "Swipe up or press close to dismiss"
    }

    /// Adds (if needed) and animates the chip into view.
    func present(in container: UIView, from _: Int = 0) {
        if superview == nil { container.addSubview(self) }
        if shouldAnimate {
            alpha = 0
            transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.alpha = 1
                self.transform = .identity
            }
        } else {
            alpha = 1
            transform = .identity
        }
        onSurfaced?()
        startAutoHideTimer()
    }

    /// Dismiss the chip. If `animated` is false, removal is immediate.
    func dismiss(animated: Bool) {
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        let work = {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -6)
        }
        let done: (Bool) -> Void = { _ in
            self.removeFromSuperview()
            self.onDismissed?()
        }

        if animated && shouldAnimate {
            UIView.animate(withDuration: 0.15, animations: work, completion: done)
        } else {
            work()
            done(true)
        }
    }

    func getCurrentSuggestion() -> String? { fullText }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        // Capsule container
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.layer.cornerRadius = 18
        capsule.layer.cornerCurve = .continuous
        capsule.layer.masksToBounds = false
        // Use your brand color if available, otherwise fallback
        let baseColor = (UIColor.keyboardRose ?? UIColor.systemPink).withAlphaComponent(0.90)
        capsule.backgroundColor = baseColor

        // Shadow (path set in layoutSubviews)
        capsule.layer.shadowColor = UIColor.black.withAlphaComponent(0.18).cgColor
        capsule.layer.shadowOpacity = enableShadows ? 1 : 0
        capsule.layer.shadowOffset = CGSize(width: 0, height: 2)
        capsule.layer.shadowRadius = 6

        // Rasterize for cheap shadow on static view
        capsule.layer.shouldRasterize = true
        capsule.layer.rasterizationScale = UIScreen.main.scale

        addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = .init(pointSize: 14, weight: .bold)
        iconView.tintColor = .white
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Label
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .white
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Chevron (expand/collapse)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        chevronButton.tintColor = .white
        chevronButton.accessibilityLabel = "Expand suggestion"
        chevronButton.addAction(UIAction { [weak self] _ in
            self?.expandIfNeeded()
        }, for: .touchUpInside)
        chevronButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Close
        var xConfig = UIButton.Configuration.plain()
        xConfig.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
        closeButton.configuration = xConfig
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = "Dismiss suggestion"
        closeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onDismiss?()
            self.dismiss(animated: true)
        }, for: .touchUpInside)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Main horizontal content
        let mainStack = UIStackView(arrangedSubviews: [iconView, textLabel, chevronButton, closeButton])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .horizontal
        mainStack.alignment = .center
        mainStack.spacing = 10
        capsule.addSubview(mainStack)

        // Compact constraints (collapsed)
        compactConstraints = [
            mainStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: compactVPad),
            mainStack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadCompact),
            mainStack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadCompact),
            mainStack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -compactVPad),
            heightAnchor.constraint(lessThanOrEqualToConstant: collapsedHeight)
        ]

        // Expanded constraints (more padding; height stretches naturally)
        expandedConstraints = [
            mainStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: expandedVPad),
            mainStack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadExpanded),
            mainStack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadExpanded),
            mainStack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -expandedVPad)
        ]

        NSLayoutConstraint.activate(compactConstraints)

        // Prevent unwanted vertical stretching
        setContentHuggingPriority(.required, for: .vertical)

        // Tap anywhere to expand
        addAction(UIAction { [weak self] _ in
            self?.expandIfNeeded()
        }, for: .touchUpInside)

        // Swipe up to dismiss
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        swipeUp.direction = .up
        addGestureRecognizer(swipeUp)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.layer.shadowOpacity = enableShadows ? 1 : 0
        capsule.layer.shadowPath = UIBezierPath(roundedRect: capsule.bounds, cornerRadius: 18).cgPath
    }

    // MARK: - Behavior

    private func expandIfNeeded() {
        guard !isExpanded else { return }
        isExpanded = true
        haptic.impactOccurred()
        onExpanded?()

        // stop auto-hide while expanded
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        // Rotate chevron and expand layout
        let rotateChevron = {
            self.chevronButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }

        if shouldAnimate {
            UIView.animate(withDuration: 0.18, animations: rotateChevron)
            UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseInOut]) {
                NSLayoutConstraint.deactivate(self.compactConstraints)
                NSLayoutConstraint.activate(self.expandedConstraints)
                self.setExpanded(fullText: self.fullText)
                self.superview?.layoutIfNeeded()
            }
        } else {
            rotateChevron()
            NSLayoutConstraint.deactivate(compactConstraints)
            NSLayoutConstraint.activate(expandedConstraints)
            setExpanded(fullText: fullText)
            superview?.layoutIfNeeded()
        }
    }

    @objc private func handleSwipeUp() {
        haptic.impactOccurred()
        onDismiss?()
        dismiss(animated: true)
    }

    // MARK: - Tone styling (no sparkles in neutral)

    private func applyTone(_ tone: ToneStatus, animated: Bool) {
        let colors = toneColors(tone)

        let applyBlock = {
            self.capsule.backgroundColor = colors.bg
            self.textLabel.textColor = colors.textColor
            self.chevronButton.tintColor = colors.iconColor
            self.closeButton.tintColor = colors.iconColor

            if let sysName = colors.iconSystemName {
                self.iconView.image = UIImage(systemName: sysName)
                self.iconView.tintColor = colors.iconColor
                self.iconView.isHidden = false
            } else {
                // Neutral tone: hide the icon entirely (removes “sparkles”)
                self.iconView.image = nil
                self.iconView.isHidden = true
            }
        }

        if animated && shouldAnimate {
            UIView.transition(with: capsule, duration: 0.15, options: .transitionCrossDissolve, animations: applyBlock)
        } else {
            applyBlock()
        }
    }

    /// Returns colors and optional SF Symbol for each tone.
    /// Note: **neutral** returns `iconSystemName = nil` to avoid the “sparkles” glyph.
    private func toneColors(_ tone: ToneStatus) -> (bg: UIColor, iconSystemName: String?, textColor: UIColor, iconColor: UIColor) {
        switch tone {
        case .neutral:
            // ✅ NEUTRAL POLISH: Dimmed slightly to differentiate "FYI" from "fix this" states
            return ((UIColor.keyboardRose ?? .systemPink).withAlphaComponent(0.82), nil, .white, .white)
        case .alert:
            return (UIColor.systemRed.withAlphaComponent(0.95), "exclamationmark.triangle.fill", .white, .white)
        case .caution:
            return (UIColor.systemYellow.withAlphaComponent(0.95), "exclamationmark.triangle.fill", .black, .black)
        case .clear:
            return (UIColor.systemGreen.withAlphaComponent(0.92), "checkmark.seal.fill", .white, .white)
        }
    }

    // MARK: - Auto-hide (collapsed only)

    private func startAutoHideTimer() {
        autoHideTimer?.invalidate()
        guard !isExpanded else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 18.0, repeats: false) { [weak self] _ in
            self?.onTimeout?()
            self?.dismiss(animated: true)
        }
        RunLoop.main.add(t, forMode: .common)
        autoHideTimer = t
    }
}

// MARK: - SuggestionChipPresenting
extension SuggestionChipView: SuggestionChipPresenting {
    func presentSuggestion(_ text: String, tone: ToneStatus) {
        setPreview(text: text, tone: tone, textHash: String(text.hashValue))
    }

    func dismissSuggestion() {
        dismiss(animated: true)
    }
}
