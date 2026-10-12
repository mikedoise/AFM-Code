//
//  MarkdownTextView.swift
//  AFM Code
//
//  Ported from Perspective Intelligence.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct MarkdownTextView: View {
    let attributedString: AttributedString
    let textColor: Color
    let baseFontSize: CGFloat
    let textAlignment: TextAlignment

    init(
        attributedString: AttributedString,
        textColor: Color,
        baseFontSize: CGFloat,
        textAlignment: TextAlignment = .leading
    ) {
        self.attributedString = attributedString
        self.textColor = textColor
        self.baseFontSize = baseFontSize
        self.textAlignment = textAlignment
    }

    var body: some View {
        platformView
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var platformView: some View {
#if os(iOS) || os(tvOS)
        MarkdownUIKitTextView(
            attributedString: attributedString,
            textColor: UIColor(textColor),
            baseFontSize: baseFontSize,
            textAlignment: textAlignment.nsTextAlignment
        )
#else
        // Use native SwiftUI Text on macOS - it sizes correctly to content
        Text(attributedString)
            .foregroundColor(textColor)
            .font(.system(size: baseFontSize))
            .multilineTextAlignment(textAlignment)
            .textSelection(.enabled)
#endif
    }
}

#if os(iOS) || os(tvOS)
private struct MarkdownUIKitTextView: UIViewRepresentable {
    let attributedString: AttributedString
    let textColor: UIColor
    let baseFontSize: CGFloat
    let textAlignment: NSTextAlignment

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownUITextView()
        textView.backgroundColor = UIColor.clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.textAlignment = textAlignment
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Skip the expensive NSAttributedString rebuild when the source
        // content has not changed. This avoids redundant work when SwiftUI
        // re-evaluates the body but the text is the same (e.g. color scheme
        // change that doesn't affect this bubble, or unrelated state change).
        let inputHash = attributedString.characters.count
        let colorChanged = context.coordinator.lastTextColor != textColor
        if context.coordinator.lastContentLength == inputHash,
           context.coordinator.lastCharacterSample == attributedString.description.hashValue,
           !colorChanged {
            return
        }
        context.coordinator.lastContentLength = inputHash
        context.coordinator.lastCharacterSample = attributedString.description.hashValue
        context.coordinator.lastTextColor = textColor

        uiView.attributedText = makeNSAttributedString()
        uiView.textColor = textColor
        uiView.textAlignment = textAlignment
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // Allow the text view to size itself to its content up to the proposed width,
        // so single-line bubbles don't stretch to the full available width.
        let proposedWidth = proposal.width ?? .greatestFiniteMagnitude
        let fittingSize = CGSize(width: proposedWidth > 0 ? proposedWidth : .greatestFiniteMagnitude,
                                 height: .greatestFiniteMagnitude)
        let result = uiView.sizeThatFits(fittingSize)
        let finalWidth = min(result.width, proposedWidth)
        // Ceiling the height to avoid fractional pixel differences that can cause
        // UICollectionView layout thrashing when combined with SwiftUI List.
        return CGSize(width: finalWidth, height: ceil(result.height))
    }

    private func makeNSAttributedString() -> NSAttributedString {
        let mutable = NSMutableAttributedString(
            attributedString: NSAttributedString(attributedString)
        )
        let range = NSRange(location: 0, length: mutable.length)
        let baseFont = UIFont.systemFont(ofSize: baseFontSize)
        let metrics = UIFontMetrics(forTextStyle: .body)
        mutable.beginEditing()
        mutable.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if let existingFont = value as? UIFont {
                // Respect any existing font choices (e.g., headings, bold, italics)
                // but scale them using Dynamic Type so that the entire message
                // responds to the user's preferred content size.
                let scaled = metrics.scaledFont(for: existingFont)
                mutable.addAttribute(.font, value: scaled, range: subrange)
            } else {
                // Apply a dynamically scaled base font for ranges that don't
                // specify a font, keeping the original base size as the
                // reference so default rendering is unchanged at .large.
                let scaledBase = metrics.scaledFont(for: baseFont)
                mutable.addAttribute(.font, value: scaledBase, range: subrange)
            }
        }
        mutable.addAttribute(.foregroundColor, value: textColor, range: range)
        mutable.endEditing()
        return mutable
    }

    /// Coordinator that caches state to skip redundant `NSAttributedString`
    /// rebuilds when the content hasn't actually changed between updates.
    final class Coordinator {
        var lastContentLength: Int = -1
        var lastCharacterSample: Int = 0
        var lastTextColor: UIColor?
    }
}

private final class MarkdownUITextView: UITextView {
    private var lastIntrinsicHeight: CGFloat = 0

    override var contentSize: CGSize {
        didSet {
            // Only invalidate when the height changes by at least 1 point to prevent
            // layout thrashing from sub-pixel differences in sizing calculations.
            let newHeight = ceil(contentSize.height)
            if abs(newHeight - lastIntrinsicHeight) >= 1 {
                lastIntrinsicHeight = newHeight
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: ceil(contentSize.height))
    }
}
#endif

#if os(iOS) || os(tvOS)
private extension TextAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:
            return .left
        case .trailing:
            return .right
        case .center:
            return .center
        }
    }
}
#endif
