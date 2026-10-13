//
//  PendingImageAttachment.swift
//  AFM Code
//
//  Represents an image that has been pasted or dropped into the
//  composer but not yet sent.  It lives only in the composer's
//  @State — once the message is sent the image is embedded in the
//  Message record and the pending attachment is discarded.
//

import Foundation
import UniformTypeIdentifiers
import AppKit

struct PendingImageAttachment: Identifiable, Hashable {
    let id: UUID

    /// Compressed JPEG data (always PNG when pasted from the
    /// pasteboard; converted to JPEG for storage efficiency).
    let jpegData: Data

    /// Suggested filename (e.g. "Pasted Image.png") used when the
    /// image was pasted from the clipboard.
    let suggestedFilename: String

    /// Content type identifier (png, jpeg, heic, …).
    let contentTypeIdentifier: String

    var fileSize: Int64 { Int64(jpegData.count) }

    var isImage: Bool {
        UTType(contentTypeIdentifier)?.conforms(to: .image) ?? false
    }

    /// A thumbnail preview (NSImage on macOS).
    var thumbnail: NSImage? {
        NSImage(data: jpegData)
    }

    /// Human-readable file size string.
    var fileSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // MARK: - Factory

    /// Create from raw image data (PNG, TIFF, etc.).  The data is
    /// re-encoded as JPEG at 0.85 quality to keep it small.
    static func from(pasteboardData: Data, suggestedFilename: String, contentTypeIdentifier: String)
        -> PendingImageAttachment?
    {
        guard let source = CGImageSourceCreateWithData(pasteboardData as CFData, nil) else {
            return nil
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        guard let jpeg = Self.jpeg(from: cgImage, quality: 0.85) else {
            return nil
        }
        let name = suggestedFilename.isEmpty ? "Pasted Image.jpg" : suggestedFilename
        return PendingImageAttachment(
            id: UUID(),
            jpegData: jpeg,
            suggestedFilename: name,
            contentTypeIdentifier: UTType.jpeg.identifier
        )
    }

    // MARK: Hashable / Equatable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PendingImageAttachment, rhs: PendingImageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Helpers

    /// Convert a CGImage to JPEG data at the given quality.
    private static func jpeg(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let bitmap = NSBitmapImageRep(
            cgImage: cgImage
        )
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
