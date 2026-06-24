//
//  AttachmentViews.swift
//  Wapo
//

import SwiftUI
import AppKit

struct ComposerAttachmentCardView: View {
    let attachment: AttachmentItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AttachmentPreviewView(attachment: attachment, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(attachment.source == .screenshot ? "Screenshot" : "File attachment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct MessageAttachmentStripView: View {
    let attachments: [AttachmentItem]
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            ForEach(attachments) { attachment in
                HStack(spacing: 8) {
                    AttachmentPreviewView(attachment: attachment, size: 24)

                    Text(attachment.displayName)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
    }
}

private struct AttachmentPreviewView: View {
    let attachment: AttachmentItem
    let size: CGFloat

    var body: some View {
        Group {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(10, size * 0.34), style: .continuous))
    }

    private var previewImage: NSImage? {
        guard attachment.source == .screenshot || isImageFile else { return nil }
        return NSImage(contentsOf: attachment.url)
    }

    private var isImageFile: Bool {
        let ext = attachment.url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains(ext)
    }
}
