import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SubtitleTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let fontSize: CGFloat
    
    init(attributedText: NSAttributedString, fontSize: CGFloat = 22) {
        self.attributedText = attributedText
        self.fontSize = fontSize
    }
    
    func makeUIView(context: Context) -> PaddedLabel {
        Self.makeLabel(fontSize: fontSize)
    }

    func updateUIView(_ uiView: PaddedLabel, context: Context) {
        Self.configure(uiView, with: attributedText, fontSize: fontSize)
    }

    // Snapshots are rendered outside the SwiftUI hierarchy. Keep their text
    // preparation on the exact same path as the on-screen secondary subtitle.
    static func snapshotLabel(
        attributedText: NSAttributedString,
        fontSize: CGFloat,
        maximumWidth: CGFloat
    ) -> PaddedLabel {
        let label = makeLabel(fontSize: fontSize)
        configure(label, with: attributedText, fontSize: fontSize)
        let size = label.sizeThatFits(
            CGSize(width: max(1, maximumWidth), height: .greatestFiniteMagnitude)
        )
        label.bounds = CGRect(origin: .zero, size: size)
        return label
    }

    private static func makeLabel(fontSize: CGFloat) -> PaddedLabel {
        let label = PaddedLabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.backgroundColor = .clear
        label.layer.cornerRadius = 0
        label.layer.masksToBounds = false
        label.textInsets = UIEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
        label.outlineColor = UIColor.black.withAlphaComponent(0.88)
        label.outlineWidth = max(1.0, fontSize * 0.075)
        return label
    }

    private static func configure(
        _ uiView: PaddedLabel,
        with attributedText: NSAttributedString,
        fontSize: CGFloat
    ) {
        // Create a mutable copy to adjust font size if needed
        let mutableAttr = NSMutableAttributedString(attributedString: attributedText)
        let range = NSRange(location: 0, length: mutableAttr.length)

        [
            NSAttributedString.Key.foregroundColor,
            NSAttributedString.Key.strokeColor,
            NSAttributedString.Key.strokeWidth,
            NSAttributedString.Key.shadow,
            NSAttributedString.Key.backgroundColor
        ].forEach { key in
            mutableAttr.removeAttribute(key, range: range)
        }
        
        // Check if font attribute exists
        var hasFont = false
        mutableAttr.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            if let font = value as? UIFont {
                hasFont = true
                let traits = font.fontDescriptor.symbolicTraits
                let weight: UIFont.Weight = traits.contains(.traitBold) ? .bold : .semibold
                let scaledFont = UIFont.systemFont(ofSize: fontSize, weight: weight)
                mutableAttr.addAttribute(.font, value: scaledFont, range: attrRange)
            }
        }
        
        // If no font attribute exists, set a proper default font for CJK text
        if !hasFont {
            // Use system font which has good CJK support on iOS
            let defaultFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            mutableAttr.addAttribute(.font, value: defaultFont, range: range)
        }

        mutableAttr.addAttribute(.foregroundColor, value: UIColor(white: 1.0, alpha: 1.0), range: range)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = max(1, fontSize * 0.1)
        mutableAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)

        uiView.outlineWidth = max(1.0, fontSize * 0.075)
        uiView.attributedText = mutableAttr
    }
}

// Custom UILabel with padding support
class PaddedLabel: UILabel {
    var textInsets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }
    var outlineColor: UIColor = UIColor.black.withAlphaComponent(0.88)
    var outlineWidth: CGFloat = 1.6
    
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetRect = bounds.inset(by: textInsets)
        let textRect = super.textRect(forBounds: insetRect, limitedToNumberOfLines: numberOfLines)
        let invertedInsets = UIEdgeInsets(
            top: -textInsets.top,
            left: -textInsets.left,
            bottom: -textInsets.bottom,
            right: -textInsets.right
        )
        return textRect.inset(by: invertedInsets)
    }
    
    override func drawText(in rect: CGRect) {
        let insetRect = rect.inset(by: textInsets)
        guard let attributedText, attributedText.length > 0 else {
            super.drawText(in: insetRect)
            return
        }

        let range = NSRange(location: 0, length: attributedText.length)
        let drawOptions: NSStringDrawingOptions = [
            .usesLineFragmentOrigin,
            .usesFontLeading
        ]

        if outlineWidth > 0 {
            let outlineText = NSMutableAttributedString(attributedString: attributedText)
            outlineText.addAttributes([
                .strokeColor: outlineColor,
                .strokeWidth: outlineWidth
            ], range: range)
            outlineText.draw(with: insetRect, options: drawOptions, context: nil)
        }

        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: 0.7),
                blur: 1.2,
                color: UIColor.black.withAlphaComponent(0.75).cgColor
            )
            attributedText.draw(with: insetRect, options: drawOptions, context: nil)
            context.restoreGState()
        } else {
            attributedText.draw(with: insetRect, options: drawOptions, context: nil)
        }
    }
    
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}
