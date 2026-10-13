//
//  ChatInputTextView.swift
//  AFM Code
//
//  Native chat input with vision support.  When the user pastes an
//  image (Cmd+V) the pasteboard is inspected for image data before
//  falling through to normal text paste.  Detected images are routed
//  through `onImagePaste` so the composer can stage them as preview
//  chips.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var isDisabled: Bool = false
    var accessibilityLabel: String? = nil
    var accessibilityHint: String = "Enter the message to send"
    var onSubmit: ((String) -> Void)?
    /// Called when the pasteboard contains image data.  The composer
    /// receives the array and stages preview chips.
    var onImagePaste: (([PendingImageAttachment]) -> Void)?

    func makeNSView(context: Context) -> FocusForwardingScrollView {
        let textView = PasteAwareTextView()
        textView.onImagePaste = onImagePaste
        textView.placeholderString = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.configureAccessibility(
            label: accessibilityLabel ?? placeholder,
            hint: accessibilityHint
        )

        let scrollView = FocusForwardingScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: FocusForwardingScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PasteAwareTextView else { return }
        context.coordinator.parent = self
        let shouldPreserveUnpublishedEdit = context.coordinator.hasUnpublishedEdit
            && text == context.coordinator.lastPublishedText
        if !shouldPreserveUnpublishedEdit, textView.string != text {
            context.coordinator.cancelPendingBindingUpdate()
            textView.string = text
            textView.needsDisplay = true
            context.coordinator.lastPublishedText = text
        }
        textView.isEditable = !isDisabled
        textView.isSelectable = true
        textView.onImagePaste = onImagePaste
        textView.placeholderString = placeholder
        textView.configureAccessibility(
            label: accessibilityLabel ?? placeholder,
            hint: accessibilityHint
        )
    }

    nonisolated func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FocusForwardingScrollView,
        context: Context
    ) -> CGSize? {
        MainActor.assumeIsolated {
            guard let textView = nsView.documentView as? PasteAwareTextView,
                  let textContainer = textView.textContainer else { return nil }

            let width = proposal.width ?? 200
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = font.boundingRectForFont.height
            let padding = textView.textContainerInset.height * 2
            let minHeight = lineHeight + padding
            let maxHeight = lineHeight * 6 + padding
            let textWidth = max(
                0,
                width - (textView.textContainerInset.width * 2) - (textContainer.lineFragmentPadding * 2)
            )
            let measuredText = textView.string.isEmpty ? " " : textView.string
            let boundingRect = (measuredText as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            let contentHeight = ceil(boundingRect.height) + padding

            return CGSize(width: width, height: min(max(contentHeight, minHeight), maxHeight))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: PasteAwareTextView?
        fileprivate var lastPublishedText: String
        fileprivate var hasUnpublishedEdit = false
        private var pendingBindingUpdate: DispatchWorkItem?
        // NSTextView renders keystrokes immediately. Publish the SwiftUI binding
        // after a short pause so the transcript hierarchy is not invalidated
        // for every character in a long conversation.
        private let bindingUpdateDelay: TimeInterval = 0.20

        init(_ parent: ChatInputTextView) {
            self.parent = parent
            self.lastPublishedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PasteAwareTextView else { return }
            scheduleBindingUpdate(textView.string)
            textView.needsDisplay = true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? PasteAwareTextView else { return }
            flushBindingUpdate(textView.string)
        }

        private func scheduleBindingUpdate(_ updatedText: String) {
            pendingBindingUpdate?.cancel()
            guard updatedText != parent.text else {
                lastPublishedText = updatedText
                hasUnpublishedEdit = false
                pendingBindingUpdate = nil
                return
            }

            hasUnpublishedEdit = true
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self,
                      let textView,
                      textView.string == updatedText else { return }
                self.parent.text = updatedText
                self.lastPublishedText = updatedText
                self.hasUnpublishedEdit = false
                self.pendingBindingUpdate = nil
            }
            pendingBindingUpdate = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + bindingUpdateDelay,
                execute: workItem
            )
        }

        fileprivate func flushBindingUpdate(_ updatedText: String) {
            pendingBindingUpdate?.cancel()
            pendingBindingUpdate = nil
            hasUnpublishedEdit = false
            lastPublishedText = updatedText
            if parent.text != updatedText {
                parent.text = updatedText
            }
        }

        fileprivate func cancelPendingBindingUpdate() {
            pendingBindingUpdate?.cancel()
            pendingBindingUpdate = nil
            hasUnpublishedEdit = false
        }

        nonisolated func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            MainActor.assumeIsolated {
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        textView.insertNewlineIgnoringFieldEditor(nil)
                        return true
                    }
                    guard let pasteAwareTextView = textView as? PasteAwareTextView else {
                        return false
                    }
                    flushBindingUpdate(pasteAwareTextView.string)
                    let submittedText = pasteAwareTextView.string
                    let submit = parent.onSubmit
                    DispatchQueue.main.async {
                        submit?(submittedText)
                    }
                    return true
                }
                return false
            }
        }
    }

    // MARK: - Custom NSView subclasses

    class FocusForwardingScrollView: NSScrollView {
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool {
            if let textView = documentView as? NSTextView {
                return window?.makeFirstResponder(textView) ?? false
            }
            return false
        }
    }

    /// NSTextView that intercepts paste to detect images on the
    /// pasteboard before falling through to normal text paste.
    /// Mirrors PI's PasteAwareTextView.
    class PasteAwareTextView: NSTextView {
        var onImagePaste: (([PendingImageAttachment]) -> Void)?
        var placeholderString: String = ""

        func configureAccessibility(label: String, hint: String) {
            setAccessibilityElement(true)
            setAccessibilityLabel(label)
            setAccessibilityHelp(hint)
            setAccessibilityIdentifier(label)
        }

        override func paste(_ sender: Any?) {
            guard isEditable else {
                super.paste(sender)
                return
            }
            let images = imageAttachments(from: .general)
            if !images.isEmpty {
                onImagePaste?(images)
                return
            }
            super.paste(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            guard isEditable else {
                super.pasteAsPlainText(sender)
                return
            }
            let images = imageAttachments(from: .general)
            if !images.isEmpty {
                onImagePaste?(images)
                return
            }
            super.pasteAsPlainText(sender)
        }

        /// Extract images from the pasteboard.  Returns an empty array
        /// when no image data is found so normal text paste proceeds.
        private func imageAttachments(from pb: NSPasteboard) -> [PendingImageAttachment] {
            let types = pb.types ?? []

            // File URLs (dragged or copied files)
            if types.contains(where: { $0.rawValue == "public.file-url" }),
               let urls = pb.readObjects(forClasses: [NSURL.self], options: [
                   .urlReadingFileURLsOnly: true
               ]) as? [URL], !urls.isEmpty {
                return urls.compactMap { url -> PendingImageAttachment? in
                    guard let data = try? Data(contentsOf: url),
                          let attachment = PendingImageAttachment.from(
                              pasteboardData: data,
                              suggestedFilename: url.lastPathComponent,
                              contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.jpeg.identifier)
                    else { return nil }
                    return attachment
                }
            }

            // Direct PNG / TIFF data from clipboard
            if let pngData = pb.data(forType: .png), !pngData.isEmpty,
               let attachment = PendingImageAttachment.from(
                   pasteboardData: pngData,
                   suggestedFilename: "Pasted Image.png",
                   contentTypeIdentifier: UTType.png.identifier) {
                return [attachment]
            }

            if let tiffData = pb.data(forType: .tiff), !tiffData.isEmpty,
               let attachment = PendingImageAttachment.from(
                   pasteboardData: tiffData,
                   suggestedFilename: "Pasted Image.tiff",
                   contentTypeIdentifier: UTType.tiff.identifier) {
                return [attachment]
            }

            // Fallback: NSImage from pasteboard → convert to PNG
            guard let image = NSImage(pasteboard: pb),
                  image.isValid,
                  image.size.width > 0,
                  image.size.height > 0 else {
                return []
            }

            let pixelWidth = Int(image.size.width)
            let pixelHeight = Int(image.size.height)
            guard let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return [] }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
            image.draw(
                in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            NSGraphicsContext.restoreGraphicsState()

            guard let pngData = bitmapRep.representation(using: .png, properties: [:]),
                  !pngData.isEmpty else {
                return []
            }

            return [PendingImageAttachment(
                id: UUID(),
                jpegData: pngData,
                suggestedFilename: "Pasted Image.png",
                contentTypeIdentifier: UTType.png.identifier
            )]
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholderString.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
            let inset = textContainerInset
            let lineFragPadding = textContainer?.lineFragmentPadding ?? 5
            let rect = NSRect(
                x: inset.width + lineFragPadding,
                y: inset.height,
                width: bounds.width - inset.width * 2 - lineFragPadding * 2,
                height: bounds.height - inset.height * 2
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }
}
