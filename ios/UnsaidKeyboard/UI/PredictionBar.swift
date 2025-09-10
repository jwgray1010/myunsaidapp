//  PredictionBar.swift
//  UnsaidKeyboard
//
//  UI-only prediction bar:
//  - Tintable brand logo (icon-only tint; no backdrop).
//  - Optional Undo button.
//  - iOS-like fixed height (taller than 44) w/ Dynamic Type nudge.
//  - No coordinator logic—controller drives it.
//
//  Public API:
//    setToneStatus(_ tone: ToneStatus)
//    setToneStatusString(_ status: String)
//    setUndoVisible(_ visible: Bool)
//    var preferredHeight: CGFloat { get }
//
//  Delegate:
//    predictionBarDidTapToneIcon()
//    predictionBarDidTapUndo()

import UIKit

@MainActor
protocol PredictionBarDelegate: AnyObject {
    func predictionBarDidTapToneIcon()
    func predictionBarDidTapUndo()
    // Reserved for future:
    func predictionBarDidRequestUndo()
    func predictionBarDidRequestSettings()
    func predictionBarDidSelectContext(_ contextId: String)
}

@MainActor
final class PredictionBar: UIView {

    weak var delegate: PredictionBarDelegate?

    // Expose a height the controller can use to size its container
    var preferredHeight: CGFloat { suggestedHeight() }

    // MARK: - Public API (UI-only)

    func setToneStatus(_ tone: ToneStatus) {
        toneButton.backgroundColor = backgroundColor(for: tone)
        currentTone = tone
    }

    func setToneStatusString(_ status: String) {
        switch status.lowercased() {
        case "alert":   setToneStatus(.alert)
        case "caution": setToneStatus(.caution)
        case "clear":   setToneStatus(.clear)
        default:        setToneStatus(.neutral)
        }
    }

    func setUndoVisible(_ visible: Bool) {
        guard undoButton.isHidden == !visible else { return }
        if visible {
            undoButton.alpha = 0
            undoButton.isHidden = false
            UIView.animate(withDuration: 0.18) { self.undoButton.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.18, animations: { self.undoButton.alpha = 0 }) { _ in
                self.undoButton.isHidden = true
            }
        }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Private UI

    private let toneButtonBackground: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .systemGray5  // Will be updated based on tone
        v.layer.cornerRadius = 22
        v.clipsToBounds = true
        return v
    }()

    private let toneButton: UIButton = {
        let b = UIButton(type: .custom)
        b.translatesAutoresizingMaskIntoConstraints = false
        // Remove background color to let logo show through
        b.backgroundColor = .clear
        b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        b.imageView?.contentMode = .scaleAspectFit
        b.layer.cornerRadius = 22  // Half of 44 for circular background
        b.clipsToBounds = true
        return b
    }()

    private let undoButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setTitle("↶", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.backgroundColor = .secondarySystemFill
        b.layer.cornerCurve = .continuous
        b.layer.cornerRadius = 16
        b.isHidden = true
        b.alpha = 0
        return b
    }()

    private var heightC: NSLayoutConstraint!
    private var currentTone: ToneStatus = .neutral

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .systemGray5
        clipsToBounds = false
        layer.zPosition = 1

        // Hairline top separator like iOS
        let sep = UIView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.backgroundColor = .separator
        addSubview(sep)

        addSubview(toneButtonBackground)
        addSubview(toneButton)
        addSubview(undoButton)

        // Actions
        toneButton.addAction(UIAction { [weak self] _ in
            self?.delegate?.predictionBarDidTapToneIcon()
            self?.pressPop()
        }, for: .touchUpInside)

        undoButton.addAction(UIAction { [weak self] _ in
            self?.delegate?.predictionBarDidTapUndo()
        }, for: .touchUpInside)

        // Load + configure logo for tinting
        configureLogoImage()

        // Layout
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            toneButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            toneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toneButton.widthAnchor.constraint(equalToConstant: 44),
            toneButton.heightAnchor.constraint(equalToConstant: 44),

            undoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            undoButton.widthAnchor.constraint(equalToConstant: 32),
            undoButton.heightAnchor.constraint(equalToConstant: 32),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 44) // safety floor
        ])

        // Taller, iOS-like height (bigger than 44)
        heightC = heightAnchor.constraint(equalToConstant: suggestedHeight())
        heightC.isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(adjustHeightForDynamicType),
            name: UIContentSizeCategory.didChangeNotification, object: nil
        )

        // Start neutral (rose)
        setToneStatus(.neutral)
    }

    // MARK: - Logo Loading

    private func configureLogoImage() {
        let keyboardBundle = Bundle(for: PredictionBar.self)
        
        // Method 1: Try direct PNG file in keyboard extension bundle (simple & reliable)
        if let logoPath = keyboardBundle.path(forResource: "unsaid_logo", ofType: "png"),
           let logoImage = UIImage(contentsOfFile: logoPath) {
            // Use original rendering mode (not template) so logo keeps its design
            toneButton.setImage(logoImage, for: .normal)
            print("✅ PredictionBar: Loaded unsaid_logo.png directly from keyboard bundle")
            return
        }
        
        // Method 2: Fallback to Asset Catalog in keyboard extension 
        if let logoImage = UIImage(named: "unsaid_logo", in: keyboardBundle, compatibleWith: nil) {
            // Use original rendering mode (not template) so logo keeps its design
            toneButton.setImage(logoImage, for: .normal)
            print("✅ PredictionBar: Loaded from keyboard Asset Catalog")
            return
        }
        
        // Method 3: Try main app bundle as last resort
        if let logoImage = UIImage(named: "unsaid_logo", in: Bundle.main, compatibleWith: nil) {
            // Use original rendering mode (not template) so logo keeps its design
            toneButton.setImage(logoImage, for: .normal)
            print("✅ PredictionBar: Loaded from main app bundle")
            return
        }
        
        // Method 4: Create a simple programmatic logo as backup
        print("❌ PredictionBar: All methods failed, creating programmatic logo")
        let image = createSimpleLogoImage()
        toneButton.setImage(image, for: .normal)
    }
    
    private func createSimpleLogoImage() -> UIImage {
        // Create a simple circular logo programmatically
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            
            // Draw a simple circular shape that represents communication
            context.cgContext.setFillColor(UIColor.systemPink.cgColor)
            context.cgContext.fillEllipse(in: rect.insetBy(dx: 4, dy: 4))
            
            // Add a simple chat bubble shape
            context.cgContext.setFillColor(UIColor.white.cgColor)
            let bubbleRect = rect.insetBy(dx: 8, dy: 8)
            context.cgContext.fillEllipse(in: bubbleRect)
        }
        
        return image.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Sizing

    @objc private func adjustHeightForDynamicType() {
        heightC.constant = suggestedHeight()
        setNeedsLayout()
    }

    private func suggestedHeight() -> CGFloat {
        let isPad = traitCollection.userInterfaceIdiom == .pad
        let isLandscapePhone = (traitCollection.userInterfaceIdiom == .phone) && (bounds.width > bounds.height)

        // Increased height to accommodate logo
        var base: CGFloat = isPad ? 70 : 70 // Increased from 56/50 to 70 for logo
        if isLandscapePhone { base = 50 } // slimmer in landscape

        // Nudge for larger content sizes
        let cat = traitCollection.preferredContentSizeCategory
        if cat.isAccessibilityCategory { base += 6 }
        else if cat >= .extraExtraLarge { base += 2 }
        return base
    }

    // MARK: - Helpers

    private func backgroundColor(for tone: ToneStatus) -> UIColor {
        switch tone {
        case .alert:   return .systemRed
        case .caution: return .systemYellow
        case .clear:   return .systemGreen
        case .neutral: return .systemGray5  // neutral matches prediction bar background
        @unknown default: return .systemGray5
        }
    }

    private func tintColor(for tone: ToneStatus) -> UIColor {
        switch tone {
        case .alert:   return .systemRed
        case .caution: return .systemYellow
        case .clear:   return .systemGreen
        case .neutral: return UIColor.keyboardRose // your brand rose/pink
        @unknown default: return .label
        }
    }

    private func pressPop() {
        let t = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.12, delay: 0,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0.8,
                       options: [.allowUserInteraction]) {
            self.toneButton.transform = t
        } completion: { _ in
            UIView.animate(withDuration: 0.12, delay: 0,
                           usingSpringWithDamping: 0.8, initialSpringVelocity: 0.6,
                           options: [.allowUserInteraction]) {
                self.toneButton.transform = .identity
            }
        }
    }
}
