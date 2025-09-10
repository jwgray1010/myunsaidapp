//
//  KeyButton.swift
//  UnsaidKeyboard
//

import UIKit

final class KeyButton: UIButton {
    /// Visual size can be smaller; taps are expanded to at least 44x44
    private let minTapSize: CGSize = CGSize(width: 44, height: 44)

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: max(base.width, 44), height: max(base.height, 44))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let bounds = self.bounds
        let widthToAdd  = max(minTapSize.width - bounds.width, 0)
        let heightToAdd = max(minTapSize.height - bounds.height, 0)
        let hitRect = bounds.insetBy(dx: -widthToAdd/2, dy: -heightToAdd/2)
        return hitRect.contains(point)
    }
}

// MARK: - Consistent Key Styling

struct KeyStyle {
    static let font = UIFontMetrics(forTextStyle: .title3)
        .scaledFont(for: .systemFont(ofSize: 23, weight: .semibold))

    static func apply(to button: KeyButton) {
        button.titleLabel?.font = font
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
    }
    
    static func applyReturnKeyStyle(to button: KeyButton) {
        apply(to: button)
        button.setTitle("Return", for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.tintColor = .label // no blue highlight
    }
}
