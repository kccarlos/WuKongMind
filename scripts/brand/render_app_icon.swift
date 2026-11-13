import AppKit
import SwiftUI

// Regenerates the PNG and SVG brand assets from SwiftUI shapes.
//
// Invoked by `scripts/brand/render_app_icon.sh`, which compiles this file
// together with `WukongMind/BrandMarkShapes.swift` and `WukongMind/BrandMark.swift`.

@MainActor
private func writePNG<V: View>(_ view: V, pixels: Int, to url: URL, opaque: Bool) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = opaque
    guard let cgImage = renderer.cgImage else {
        throw CocoaError(.coderInvalidValue)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: url, options: .atomic)
}

private func markSVG() -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><clipPath id="c"><rect width="1024" height="1024" rx="230"></rect></clipPath><g clip-path="url(#c)"><rect width="512" height="1024" fill="\(BrandPalette.inkHex)"></rect><rect x="512" width="512" height="1024" fill="\(BrandPalette.goldHex)"></rect><clipPath id="l"><rect width="512" height="1024"></rect></clipPath><clipPath id="r"><rect x="512" width="512" height="1024"></rect></clipPath><g clip-path="url(#l)"><circle cx="512" cy="512" r="130" fill="none" stroke="\(BrandPalette.goldHex)" stroke-width="28"></circle><circle cx="512" cy="512" r="235" fill="none" stroke="\(BrandPalette.goldHex)" stroke-width="28"></circle><circle cx="512" cy="512" r="340" fill="none" stroke="\(BrandPalette.goldHex)" stroke-width="28"></circle></g><g clip-path="url(#r)"><circle cx="512" cy="512" r="130" fill="none" stroke="\(BrandPalette.inkHex)" stroke-width="28"></circle><circle cx="512" cy="512" r="235" fill="none" stroke="\(BrandPalette.inkHex)" stroke-width="28"></circle><circle cx="512" cy="512" r="340" fill="none" stroke="\(BrandPalette.inkHex)" stroke-width="28"></circle></g></g></svg>
    """
}

@main
enum RenderAppIcon {
    static func main() throws {
        let root = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? FileManager.default.currentDirectoryPath
        )

        let icon = BrandAppIcon(size: 1024)
        let appIconURL = root.appendingPathComponent("WukongMind/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
        let docsIconURL = root.appendingPathComponent("docs/brand/wukongmind-icon-1024.png")
        let docsSVGURL = root.appendingPathComponent("docs/brand/wukongmind-mark.svg")

        try MainActor.assumeIsolated {
            try writePNG(icon, pixels: 1024, to: appIconURL, opaque: true)
            try writePNG(icon, pixels: 1024, to: docsIconURL, opaque: true)
        }
        try FileManager.default.createDirectory(
            at: docsSVGURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(markSVG().utf8).write(to: docsSVGURL, options: .atomic)

        for url in [appIconURL, docsIconURL, docsSVGURL] {
            print("wrote \(url.path)")
        }
    }
}
