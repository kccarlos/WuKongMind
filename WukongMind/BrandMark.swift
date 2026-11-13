import SwiftUI

/// The WukongMind logo mark: a rounded square split down the middle between ink
/// (`#1A1612`) and gold (`#E0B040`), crossed by three concentric rings that
/// invert across the seam. Shapes live in `BrandMarkShapes.swift`.
struct BrandMark: View {
    enum Variant: String, CaseIterable, Sendable {
        case color
        case monoInk
        case monoPaper
    }

    var size: CGFloat = 72
    var variant: Variant = .color

    private var cornerRadius: CGFloat { size * BrandGeometry.cornerRadiusRatio }
    private var borderWidth: CGFloat { size * BrandGeometry.strokeWidthRatio }

    var body: some View {
        let clipShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            switch variant {
            case .color:
                HStack(spacing: 0) {
                    BrandPalette.ink
                    BrandPalette.gold
                }
                BrandHalfRingsShape(isLeft: true)
                    .fill(BrandPalette.gold)
                BrandHalfRingsShape(isLeft: false)
                    .fill(BrandPalette.ink)
            case .monoInk:
                monoMark(foreground: BrandPalette.ink, clipShape: clipShape)
            case .monoPaper:
                monoMark(foreground: BrandPalette.paper, clipShape: clipShape)
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func monoMark(foreground: Color, clipShape: RoundedRectangle) -> some View {
        BrandHalfRingsShape(isLeft: true, includeHalfPlane: true)
            .fill(foreground, style: FillStyle(eoFill: true))
        BrandHalfRingsShape(isLeft: false)
            .fill(foreground)
        clipShape
            .strokeBorder(foreground, lineWidth: borderWidth)
    }
}

/// Full-bleed square canvas for `Assets.xcassets/AppIcon.appiconset` (iOS masks
/// the icon squircle itself).
struct BrandAppIcon: View {
    var size: CGFloat = 1024

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                BrandPalette.ink
                BrandPalette.gold
            }
            BrandHalfRingsShape(isLeft: true)
                .fill(BrandPalette.gold)
            BrandHalfRingsShape(isLeft: false)
                .fill(BrandPalette.ink)
        }
        .frame(width: size, height: size)
    }
}
