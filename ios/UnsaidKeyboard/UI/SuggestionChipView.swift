//
//  SuggestionChipView.swift
//  UnsaidKeyboard
//
//  Lightweight, accessible s    /// Sets the collapsed preview content and visual tone.
    /// Note: In **neutral** tone we intentionally hide the icon (no "sparkles").

//  adaptive animations, and no “sparkles” icon in neutral state.
//

import UIKit
import os.log

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
    private let textLabel = UILabel()               // collapsed preview
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
    private var autoHideTimer: Timer?
    private var textHash: String = ""
    private var didNotifyDismiss = false
    private var hasDismissed = false

    // MARK: - Paging state (no UIScrollView)
    private var pages: [NSRange] = []
    private var currentPage = 0
    private let layoutManager = NSLayoutManager()
    private let textStorage = NSTextStorage()
    private let textContainer = NSTextContainer(size: .zero)
    
    // How many lines per page when expanded (tweak to taste)
    private let linesPerPageExpanded = 4

    // Layout
    private let collapsedHeight: CGFloat = 44
    private let compactVPad: CGFloat = 8
    private let expandedVPad: CGFloat = 12
    private let hPadCompact: CGFloat = 12
    private let hPadExpanded: CGFloat = 16

    private var compactConstraints: [NSLayoutConstraint] = []
    private var expandedConstraints: [NSLayoutConstraint] = []
    private var maxExpandedHeightConstraint: NSLayoutConstraint?

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
    /// Note: In **neutral** tone we intentionally hide the icon (no "sparkles").
    func setPreview(text: String, tone: ToneStatus, textHash: String) {
        self.fullText = text
        self.textHash = textHash

        textLabel.isHidden = false
        textLabel.text = text
        textLabel.numberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail

        // reset expanded views
        scrollView.isHidden = true
        textView.text = ""
        
        applyTone(tone, animated: false)

        // Accessibility
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        accessibilityLabel = "Suggestion"
        accessibilityValue = text
        accessibilityHint = "Tap to expand"

        // Prepare unified haptics for near-term interaction
        UnifiedHapticsController.shared.start()
    }

    /// Sets the fully expanded content layout.
    func setExpanded(fullText: String) {
        // show scrollable body
        textLabel.isHidden = true
        scrollView.isHidden = false
        textView.text = fullText
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
        guard !hasDismissed else { return }
        hasDismissed = true
        
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        // ✅ DEFENSIVE: Ensure we notify dismissal exactly once
        if !didNotifyDismiss {
            didNotifyDismiss = true
            #if DEBUG
            KBDLog("🗑️ ChipView: Dismissing chip, notifying manager", .debug, "Chips")
            #endif
            onDismiss?()
        } else {
            #if DEBUG
            KBDLog("⚠️ ChipView: Dismiss already notified, skipping", .debug, "Chips")
            #endif
        }

        let work = {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        let done: (Bool) -> Void = { _ in
            #if DEBUG
            KBDLog("🏁 ChipView: Animation complete, calling onDismissed", .debug, "Chips")
            #endif
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

        // TextKit plumbing
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        // Expanded scrollable text
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true     // hidden in collapsed mode
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.contentInset = .zero

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = false   // let scrollView handle scrolling
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 15, weight: .semibold)
        textView.textContainerInset = .init(top: 0, left: 0, bottom: 0, right: 0)
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

        // Chevron (expand/collapse)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        chevronButton.tintColor = .white
        chevronButton.accessibilityLabel = "Expand suggestion"
        chevronButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if !self.isExpanded { self.expandIfNeeded(); return }
            self.advancePageIfPossible()
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
            heightAnchor.constraint(lessThanOrEqualToConstant: collapsedHeight),

            // keep scrollView out of layout when hidden
            scrollView.topAnchor.constraint(equalTo: mainStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadCompact),
            scrollView.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadCompact),
            scrollView.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -compactVPad),
            scrollView.heightAnchor.constraint(equalToConstant: 0) // collapsed state keeps it zero
        ]

        // Expanded constraints
        expandedConstraints = [
            // top row (icon + chevron + close) remains
            mainStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: expandedVPad),
            mainStack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadExpanded),
            mainStack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadExpanded),

            // scrollable body below
            scrollView.topAnchor.constraint(equalTo: mainStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: hPadExpanded),
            scrollView.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -hPadExpanded),
            scrollView.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -expandedVPad)
        ]

        // cap max expanded height (~40% of container height, clamped)
        let maxH: CGFloat = 160   // good default for keyboard area
        maxExpandedHeightConstraint = heightAnchor.constraint(lessThanOrEqualToConstant: maxH)
        // (Activate this only while expanded)

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
        
        // Keep pages in sync with size changes
        if isExpanded {
            let oldWidth = textContainer.size.width
            let newWidth = max(10, capsule.bounds.width - (hPadExpanded * 2))
            if abs(newWidth - oldWidth) > 0.5 {  // reflow only on meaningful changes
                recomputePages()
                currentPage = min(currentPage, max(0, pages.count - 1))
                showCurrentPage()
            }
        }
    }

    // MARK: - Behavior

    private func expandIfNeeded() {
        guard !isExpanded else { 
            advancePageIfPossible()
            return
        }
        isExpanded = true
        UnifiedHapticsController.shared.selection()
        onExpanded?()

        autoHideTimer?.invalidate(); autoHideTimer = nil

        // Rotate chevron
        let rotateChevron = { self.chevronButton.transform = CGAffineTransform(rotationAngle: .pi / 2) }

        if shouldAnimate { UIView.animate(withDuration: 0.18) { rotateChevron() } } else { rotateChevron() }

        // Switch to expanded constraints & compute pages for current width
        NSLayoutConstraint.deactivate(compactConstraints)
        NSLayoutConstraint.activate(expandedConstraints)
        setExpanded(fullText: fullText)

        // Build pages based on current width and target line count
        recomputePages()
        currentPage = 0
        showCurrentPage()

        superview?.layoutIfNeeded()
    }

    @objc private func handleSwipeUp() {
        UnifiedHapticsController.shared.lightTap()
        onDismiss?()
        dismiss(animated: true)
    }

    // MARK: - Tone styling (no sparkles in neutral)

    private func applyTone(_ tone: ToneStatus, animated: Bool) {
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

    // MARK: - Page Computation and Navigation

    private func recomputePages() {
        guard isExpanded else { pages = []; currentPage = 0; return }

        // Measure with the label's available width
        let width = max(10, capsule.bounds.width - (hPadExpanded * 2))
        let height = CGFloat.greatestFiniteMagnitude
        textContainer.size = CGSize(width: width, height: height)

        // Build attributed string matching the label's look
        let attr = NSMutableAttributedString(string: fullText)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        attr.addAttributes([
            .font: textLabel.font as Any,
            .foregroundColor: textLabel.textColor as Any,
            .paragraphStyle: style
        ], range: NSRange(location: 0, length: attr.length))

        textStorage.setAttributedString(attr)

        // Walk line fragments and group into page ranges
        var lineRanges: [NSRange] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineRange = NSRange(location: 0, length: 0)
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            lineRanges.append(lineRange)
            glyphIndex = NSMaxRange(lineRange)
        }

        // Group every N lines into a page
        pages.removeAll(keepingCapacity: true)
        var i = 0
        while i < lineRanges.count {
            let slice = Array(lineRanges[i..<min(i + linesPerPageExpanded, lineRanges.count)])
            let loc = slice.first!.location
            let len = NSMaxRange(slice.last!) - loc
            pages.append(NSRange(location: loc, length: len))
            i += linesPerPageExpanded
        }

        // Fall back to single page if we didn't detect lines (very short text)
        if pages.isEmpty {
            pages = [NSRange(location: 0, length: textStorage.length)]
        }

        // Show/hide chevron depending on more pages
        chevronButton.isHidden = (pages.count <= 1)
    }

    private func showCurrentPage() {
        guard currentPage < pages.count else { return }
        let page = pages[currentPage]
        // Keep the label multi-line but clamp the visible substring to this page
        let visible = (textStorage.string as NSString).substring(with: page)
        textLabel.text = visible

        // If last page, dim or hide chevron
        chevronButton.alpha = (currentPage == pages.count - 1) ? 0.3 : 1.0
        chevronButton.isEnabled = (currentPage < pages.count - 1)
    }

    private func advancePageIfPossible() {
        guard isExpanded else { expandIfNeeded(); return }
        guard currentPage + 1 < pages.count else {
            // Optional behaviors on last page:
            // 1) Dismiss:
            // onDismiss?(); dismiss(animated: true); return
            // 2) Collapse back to preview:
            collapseToPreview(); return
        }
        currentPage += 1
        UnifiedHapticsController.shared.lightTap()
        if shouldAnimate {
            UIView.transition(with: textLabel, duration: 0.18, options: .transitionCrossDissolve) { self.showCurrentPage() }
        } else {
            showCurrentPage()
        }
    }

    private func collapseToPreview() {
        isExpanded = false
        chevronButton.transform = .identity
        NSLayoutConstraint.deactivate(expandedConstraints)
        NSLayoutConstraint.activate(compactConstraints)
        setPreview(text: fullText, tone: .neutral, textHash: textHash) // tone will be reapplied by presenter
        superview?.layoutIfNeeded()
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

// MARK: - Logging
extension OSLog {
    static let chips = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.example.unsaid.UnsaidKeyboard", category: "chips")
}