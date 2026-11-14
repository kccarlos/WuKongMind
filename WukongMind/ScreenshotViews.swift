import ImageIO
import SwiftUI
import UIKit

// Screenshot thumbnail and full-size sheet (design-m3.md, "Tool rows" and top Design notes).

enum ScreenshotLabel {
    case before, after

    var text: String {
        switch self {
        case .before: String(localized: "Before", comment: "Label over the screenshot taken before a page change")
        case .after: String(localized: "After", comment: "Label over the screenshot taken after a page change")
        }
    }
}

struct ScreenshotSheetItem: Identifiable {
    let id = UUID()
    var image: AgentImage
    var title: String
    var subtitle: String
}

/// Decodes `AgentImage` data off the main thread. A missing or unreadable image is `nil`.
enum AgentImageLoader {
    static func decode(_ image: AgentImage) -> Data? {
        guard !image.data.isEmpty else { return nil }
        return Data(base64Encoded: image.data)
    }

    /// Downsampled to `maxPixel` on the long edge, never decoding the full bitmap.
    static func thumbnail(_ image: AgentImage, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = decode(image),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }

    static func full(_ image: AgentImage) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            decode(image).flatMap { UIImage(data: $0) }
        }.value
    }
}

/// One or two thumbnails in an expanded tool row; two are labelled Before and After.
struct DCScreenshotStrip: View {
    let row: BrowserAgentToolCallRow
    let onOpen: (ScreenshotSheetItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(row.images.enumerated()), id: \.offset) { index, image in
                let label = Self.label(index: index, count: row.images.count)
                VStack(alignment: .leading, spacing: 4) {
                    if let label {
                        Text(verbatim: label.text).font(.caption.weight(.semibold)).foregroundStyle(DCTheme.inkMuted)
                    }
                    DCScreenshotThumbnail(image: image, label: label) {
                        onOpen(ScreenshotSheetItem(
                            image: image,
                            title: label?.text ?? String(localized: "Screenshot", comment: "Title of the full-size screenshot sheet"),
                            subtitle: String(localized: "\(row.resultSummary) · step \(row.stepNumber)", comment: "Subtitle of the full-size screenshot sheet: the capture summary and the step number")
                        ))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    static func label(index: Int, count: Int) -> ScreenshotLabel? {
        guard count == 2 else { return nil }
        return index == 0 ? .before : .after
    }
}

struct DCScreenshotThumbnail: View {
    let image: AgentImage
    var label: ScreenshotLabel?
    let onOpen: () -> Void
    @State private var loaded: UIImage?
    @State private var failed = false

    private var accessibilityText: String {
        if failed { return String(localized: "Screenshot unavailable", comment: "VoiceOver label of a screenshot thumbnail whose image is gone") }
        switch label {
        case .before: return String(localized: "Screenshot before the change, opens full size", comment: "VoiceOver label of the before thumbnail")
        case .after: return String(localized: "Screenshot after the change, opens full size", comment: "VoiceOver label of the after thumbnail")
        case nil: return String(localized: "Screenshot, opens full size", comment: "VoiceOver label of a screenshot thumbnail")
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
        Button { DCHaptics.tap(); onOpen() } label: {
            Group {
                if let loaded {
                    Image(uiImage: loaded).resizable().scaledToFit()
                } else {
                    Color.clear.overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(DCTheme.inkFaint)
                        } else {
                            ProgressView()
                        }
                    }
                    .aspectRatio(0.46, contentMode: .fit)
                }
            }
            .frame(width: 90)
            .clipShape(shape)
            .overlay(shape.strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(failed)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityIdentifier(failed ? "agentToolScreenshotMissing" : "agentToolScreenshot")
        .task(id: image.data.count) {
            loaded = await AgentImageLoader.thumbnail(image, maxPixel: 360)
            failed = loaded == nil
        }
    }
}

struct DCScreenshotSheet: View {
    let item: ScreenshotSheetItem
    @State private var loaded: UIImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let loaded {
                        Image(uiImage: loaded).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                                .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth))
                            .frame(width: (geo.size.width - 32) * min(4, max(1, zoom * pinch)))
                            .padding(16)
                            .accessibilityIdentifier("agentScreenshotImage")
                    } else {
                        Group {
                            if failed {
                                Text("This screenshot is no longer available.", comment: "Shown in the full-size screenshot sheet when the image is gone")
                                    .font(.subheadline).foregroundStyle(DCTheme.inkMuted)
                                    .accessibilityIdentifier("agentScreenshotMissing")
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { zoom = min(4, max(1, zoom * $0.magnification)) })
            }
            .background(DCTheme.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(verbatim: item.title).font(.headline)
                        Text(verbatim: item.subtitle).font(.caption).foregroundStyle(DCTheme.inkMuted)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Done", comment: "Closes the full-size screenshot sheet").bold().foregroundStyle(DCTheme.goldInk) }
                        .accessibilityIdentifier("agentScreenshotDone")
                }
            }
        }
        .task {
            loaded = await AgentImageLoader.full(item.image)
            failed = loaded == nil
        }
        .accessibilityIdentifier("agentScreenshotSheet")
    }
}
