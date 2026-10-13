//
//  ImageAttachmentView.swift
//  AFM Code
//
//  Displays an attached image in the composer preview area and in
//  message bubbles.  Supports copy and removal.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Composer preview card

struct ImageAttachmentPreviewCard: View {
    let attachment: PendingImageAttachment
    let removeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            imagePreview
                .frame(maxWidth: 156, maxHeight: 120)

            Text(attachment.suggestedFilename)
                .font(.caption2)
                .lineLimit(1)

            Text(attachment.fileSizeDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 172)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.platformTextBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.platformSeparator.opacity(0.2), lineWidth: 0.5)
        )
        .contextMenu {
            Button("Copy Image") { copyImage() }
        }
        .accessibilityLabel("Attached image: \(attachment.suggestedFilename)")
    }

    private var imagePreview: some View {
        Group {
            if let nsImage = attachment.thumbnail {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 156, maxHeight: 120)
                    .clipped()
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            removeButton
        }
    }

    private var removeButton: some View {
        Button(action: removeAction) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.7))
                .background(
                    Circle().fill(Color.platformWindowBackground)
                        .frame(width: 18, height: 18)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove image")
    }

    // MARK: - Actions

    private func copyImage() {
        guard let nsImage = attachment.thumbnail else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }
}

// MARK: - Message bubble image

struct AttachedImageView: View {
    let imageData: Data
    let filename: String

    var body: some View {
        Group {
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400)
                    .cornerRadius(8)
                    .contextMenu {
                        Button("Copy Image") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.writeObjects([nsImage])
                        }
                        Button("Save Image…") { saveImage(nsImage) }
                    }
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func saveImage(_ nsImage: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = filename.replacingOccurrences(of: ".jpg", with: "").replacingOccurrences(of: ".jpeg", with: "")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let tiffRep = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffRep),
               let encoded = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? encoded.write(to: url)
            }
        }
    }
}
