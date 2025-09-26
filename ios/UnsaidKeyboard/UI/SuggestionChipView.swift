import UIKit
import os.log

@MainActor
protocol SuggestionChipPresenting: AnyObject {
    func presentSuggestion(_ text: String, tone: ToneStatus)
    func dismissSuggestion()
}

@MainActor
final class SuggestionChipView: UIControl {

    // MARK: - Views
    private let capsule = UIView()
    private let iconView = UIImageView()
    private let textLabel = UILabel()               // collapsed preview (paged)
    private let scrollView = UIScrollView()         // expanded container
    private let textView = UITextView()             // expanded, scrollable
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
    private var autoHideToken: TimerToken?
    private var textHash: String = ""
    private var didNotifyDismiss = false
    private var hasDismissed = false
    private var lastTone: ToneStatus = .neutral

    // MARK: - Constraint management
    private var positionConstraints: [NSLayoutConstraint] = []
    private weak var attachedContainer: UIView?

    // MARK: - Paging (collapsed only)
    private var pages: [NSRange] = []
    private var currentPage = 0
    private let layoutManager = NSLayoutManager()
    private let textStorage = NSTextStorage()
    private let textContainer = NSTextContainer(size: .zero)
    private let linesPerPageCollapsed = 3

    // MARK: - Layout metrics
    private let collapsedHeight: CGFloat = 44
    private let compactVPad: CGFloat = 8
    private let expandedVPad: CGFloat = 12
    private let hPadCompact: CGFloat = 12
    private let hPadExpanded: CGFloat = 16

    private var compactConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var maxExpandedHeightConstraint: NSLayoutConstraint?

    // MARK: - Performance toggles
    private var enableShadows: Bool { !ProcessInfo.processInfo.isLowPowerModeEnabled }
    private var shouldAnimate: Bool { !UIAccessibility.isReduceMotionEnabled }

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
        if let token = autoHideToken {
            TimerHub.shared.cancel(token: token)
        }
        // Clean up constraints to prevent memory leaks
        NSLayoutConstraint.deactivate(positionConstraints)
        positionConstraints.removeAll()
    }

    // MARK: - Public

    /// Sets the collapsed preview content and visual tone.
    /// Note: In **neutral** tone we intentionally hide the icon (no "sparkles").
    func setPreview(text: String, tone: ToneStatus, textHash: String) {
        self.fullText = text
        self.textHash = textHash

        // collapsed visible elements
        textLabel.isHidden = false
        textLabel.numberOfLines = linesPerPageCollapsed
        textLabel.lineBreakMode = .byWordWrapping

        // expanded views hidden/reset
        scrollView.isHidden = true
        textView.text = ""
        textView.isScrollEnabled = false

        applyTone(tone, animated: false)

        // collapsed paging
        recomputePagesForCollapsed()
        currentPage = 0
        showCurrentPage()

        // Accessibility
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        accessibilityLabel = "Suggestion — \(tone.rawValue.capitalized)"
        accessibilityValue = text
        accessibilityHint = "Tap to expand"

        // Prepare unified haptics for near-term interaction
        UnifiedHapticsController.shared.start()
    }

    /// Sets the fully expanded content layout.
    func setExpanded(fullText: String) {
        textLabel.isHidden = true
        scrollView.isHidden = false
        textView.text = fullText
        textView.isScrollEnabled = true
        accessibilityValue = fullText
        accessibilityHint = "Swipe up or press close to dismiss"
    }

    /// Adds (if needed) and animates the chip into view.
    func present(in container: UIView, from _: Int = 0) {
        // Ensure correct parent
        if superview !== container {
            removeFromSuperview()
            container.addSubview(self)
        }
        attachedContainer = container

        // Pin safely (only after we're in the hierarchy)
        NSLayoutConstraint.deactivate(positionConstraints)
        translatesAutoresizingMaskIntoConstraints = false
        positionConstraints = [
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ]
        NSLayoutConstraint.activate(positionConstraints)
        container.layoutIfNeeded()

        // Animate in
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
        guard !hasDismissed else { return }
        hasDismissed = true

        if let token = autoHideToken {
            TimerHub.shared.cancel(token: token)
        }
        autoHideToken = nil

        // Notify dismissal once
        if !didNotifyDismiss {
            didNotifyDismiss = true
            #if DEBUG
            KBDLog("🗑️ ChipView: Dismissing chip, notifying manager", .debug, "Chips")
            #endif
            onDismiss?()
        }

        let work = {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        let done: (Bool) -> Void = { _ in
            #if DEBUG
            KBDLog("🏁 ChipView: Animation complete, calling onDismissed", .debug, "Chips")
            #endif
            // Clean up position constraints to avoid zombies
            NSLayoutConstraint.deactivate(self.positionConstraints)
            self.positionConstraints.removeAll()
            self.attachedContainer = nil
            
            self.onDismissed?()
            self.removeFromSuperview()
        }

        if animated && shouldAnimate {
            UIView.animate(withDuration: 0.20, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: work, completion: done)
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

        let baseColor = (UIColor.keyboardRose ?? UIColor.systemPink).withAlphaComponent(0.90)
        capsule.backgroundColor = baseColor

        capsule.layer.shadowColor = UIColor.black.withAlphaComponent(0.18).cgColor
        capsule.layer.shadowOpacity = enableShadows ? 1 : 0
        capsule.layer.shadowOffset = CGSize(width: 0, height: 2)
        capsule.layer.shadowRadius = 6
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

        // TextKit plumbing for collapsed pagination
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        // Expanded scrollable text
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.contentInset = .zero

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 15, weight: .semibold)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityTraits.insert(.staticText)

        scrollView.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // Chevron (expand or advance page when collapsed)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        chevronButton.tintColor = .white
        chevronButton.accessibilityLabel = "Expand suggestion"
        chevronButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if !self.isExpanded {
                // First tap expands; second tap (while still collapsed) can advance page if desired.
                // Model A: expand on tap; paging via repeated taps is optional. We'll advance page on repeated taps before expanding.
                if self.currentPage < self.pages.count - 1 {
                    self.advancePageIfPossible()
                } else {
                    self.expandIfNeeded()
                }
            }
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

        // Put scrollView under mainStack to span full width when expanded
        capsule.addSubview(scrollView)

        // Compact constraints (collapsed)
        compactConstraints = [
            mainStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: compactVPad),
            mainStack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadCompact),
            mainStack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadCompact),
            mainStack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -compactVPad),

            scrollView.topAnchor.constraint(equalTo: mainStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadCompact),
            scrollView.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadCompact),
            scrollView.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -compactVPad),
            scrollView.heightAnchor.constraint(equalToConstant: 0) // hidden in collapsed state
        ]

        // Expanded constraints
        expandedConstraints = [
            mainStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: expandedVPad),
            mainStack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadExpanded),
            mainStack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadExpanded),

            scrollView.topAnchor.constraint(equalTo: mainStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadExpanded),
            scrollView.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadExpanded),
            scrollView.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -expandedVPad)
        ]

        // cap max expanded height
        let maxH: CGFloat = 160
        maxExpandedHeightConstraint = heightAnchor.constraint(lessThanOrEqualToConstant: maxH)

        NSLayoutConstraint.activate(compactConstraints)

        // Prevent unwanted vertical stretching
        setContentHuggingPriority(.required, for: .vertical)

        // Tap anywhere to expand
        addAction(UIAction { [weak self] _ in self?.expandIfNeeded() }, for: .touchUpInside)

        // Swipe up to dismiss
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        swipeUp.direction = .up
        addGestureRecognizer(swipeUp)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.layer.shadowOpacity = enableShadows ? 1 : 0
        capsule.layer.shadowPath = UIBezierPath(roundedRect: capsule.bounds, cornerRadius: 18).cgPath

        // Keep pages in sync with size changes while collapsed
        if !isExpanded {
            let newWidth = max(10, capsule.bounds.width - (hPadCompact * 2))
            if abs(newWidth - textContainer.size.width) > 0.5 {
                recomputePagesForCollapsed()
                showCurrentPage()
            }
        }
    }

    // MARK: - Behavior

    private func expandIfNeeded() {
        guard !isExpanded else { return }
        isExpanded = true
        UnifiedHapticsController.shared.selection()
        onExpanded?()

        if let token = autoHideToken {
            TimerHub.shared.cancel(token: token)
        }
        autoHideToken = nil

        // hide chevron in expanded model A
        let changeChevron = {
            self.chevronButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
            self.chevronButton.isHidden = true
            self.chevronButton.isEnabled = false
        }
        if shouldAnimate {
            UIView.animate(withDuration: 0.18) { changeChevron() }
        } else {
            changeChevron()
        }

        // Switch constraints, populate expanded body
        NSLayoutConstraint.deactivate(compactConstraints)
        NSLayoutConstraint.activate(expandedConstraints)
        maxExpandedHeightConstraint?.isActive = true
        setExpanded(fullText: fullText)

        superview?.layoutIfNeeded()
    }

    @objc private func handleSwipeUp() {
        UnifiedHapticsController.shared.lightTap()
        onDismiss?()
        dismiss(animated: true)
    }

    // MARK: - Tone styling (no sparkles in neutral)
    private func applyTone(_ tone: ToneStatus, animated: Bool) {
        lastTone = tone
        let colors = toneColors(tone)

        let applyBlock = {
            self.capsule.backgroundColor = colors.bg
            self.textLabel.textColor = colors.textColor
            self.textView.textColor = colors.textColor
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

            // A11y strings that reflect tone & state
            self.accessibilityLabel = "Suggestion — \(tone.rawValue.capitalized)"
            self.accessibilityHint = self.isExpanded ? "Swipe up or press close to dismiss" : "Tap to expand"
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
            return ((UIColor.keyboardRose ?? .systemPink).withAlphaComponent(0.82), nil, .white, .white)
        case .alert:
            return (UIColor.systemRed.withAlphaComponent(0.95), "exclamationmark.triangle.fill", .white, .white)
        case .caution:
            return (UIColor.systemYellow.withAlphaComponent(0.95), "exclamationmark.triangle.fill", .black, .black)
        case .clear:
            return (UIColor.systemGreen.withAlphaComponent(0.92), "checkmark.seal.fill", .white, .white)
        }
    }

    // MARK: - Collapsed paging

    private func recomputePagesForCollapsed() {
        // Build attributed string to measure with label’s style
        let attr = NSMutableAttributedString(string: fullText)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        attr.addAttributes([
            .font: textLabel.font as Any,
            .foregroundColor: textLabel.textColor as Any,
            .paragraphStyle: style
        ], range: NSRange(location: 0, length: attr.length))

        textStorage.setAttributedString(attr)

        // Measure with compact width
        let width = max(10, capsule.bounds.width - (hPadCompact * 2))
        textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)

        // Walk line fragments
        var lineRanges: [NSRange] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            lineRanges.append(lineRange)
            glyphIndex = NSMaxRange(lineRange)
        }

        // Group into pages of N lines
        pages.removeAll(keepingCapacity: true)
        var i = 0
        while i < lineRanges.count {
            let slice = Array(lineRanges[i..<min(i + linesPerPageCollapsed, lineRanges.count)])
            guard let first = slice.first, let last = slice.last else { break }
            let loc = first.location
            let len = NSMaxRange(last) - loc
            pages.append(NSRange(location: loc, length: len))
            i += linesPerPageCollapsed
        }

        if pages.isEmpty {
            pages = [NSRange(location: 0, length: textStorage.length)]
        }

        // Chevron visible if there are multiple pages (collapsed only)
        if !isExpanded {
            chevronButton.isHidden = (pages.count <= 1)
            chevronButton.alpha = 1.0
            chevronButton.isEnabled = (pages.count > 1)
        }
    }

    private func showCurrentPage() {
        guard currentPage < pages.count else { return }
        let page = pages[currentPage]
        let visible = (textStorage.string as NSString).substring(with: page)
        textLabel.text = visible

        if !isExpanded {
            let isLast = (currentPage == pages.count - 1)
            chevronButton.alpha = isLast ? 0.3 : 1.0
            chevronButton.isEnabled = !isLast
        }
    }

    private func advancePageIfPossible() {
        guard !isExpanded else { return } // model A: no paging while expanded
        guard currentPage + 1 < pages.count else {
            // At last page -> expand
            expandIfNeeded()
            return
        }
        currentPage += 1
        UnifiedHapticsController.shared.lightTap()
        if shouldAnimate {
            UIView.transition(with: textLabel, duration: 0.18, options: .transitionCrossDissolve) {
                self.showCurrentPage()
            }
        } else {
            showCurrentPage()
        }
    }

    private func collapseToPreview() {
        isExpanded = false
        chevronButton.transform = .identity
        chevronButton.isHidden = false
        chevronButton.isEnabled = true
        NSLayoutConstraint.deactivate(expandedConstraints)
        maxExpandedHeightConstraint?.isActive = false
        NSLayoutConstraint.activate(compactConstraints)
        setPreview(text: fullText, tone: lastTone, textHash: textHash)
        superview?.layoutIfNeeded()
    }

    // MARK: - Auto-hide (collapsed only)
    private func startAutoHideTimer() {
        if let token = autoHideToken {
            TimerHub.shared.cancel(token: token)
        }
        guard !isExpanded else { return }
        autoHideToken = TimerHub.shared.schedule(after: 18) { [weak self] in
            self?.onTimeout?()
            self?.dismiss(animated: true)
        }
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

// MARK: - Logging
extension OSLog {
    static let chips = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.example.unsaid.UnsaidKeyboard", category: "chips")
}
