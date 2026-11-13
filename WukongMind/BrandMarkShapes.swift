import SwiftUI

// MARK: - Brand palette & geometry

/// Fixed brand colours and geometry from `design-system/assets/Logo/` (`mark.svg`,
/// `mark-mono-ink.svg`, `mark-mono-paper.svg`, `app-icon.svg`). Kept pure SwiftUI
/// so the app, share extension and `scripts/brand/render_app_icon.sh` share one source.
enum BrandPalette {
    /// Warm ink (`#1A1612`).
    static let ink = Color(.sRGB, red: 0x1A / 255.0, green: 0x16 / 255.0, blue: 0x12 / 255.0, opacity: 1)
    /// Gold leaf (`#E0B040`).
    static let gold = Color(.sRGB, red: 0xE0 / 255.0, green: 0xB0 / 255.0, blue: 0x40 / 255.0, opacity: 1)
    /// Warm paper (`#F7F3EA`).
    static let paper = Color(.sRGB, red: 0xF7 / 255.0, green: 0xF3 / 255.0, blue: 0xEA / 255.0, opacity: 1)

    static let inkHex = "#1a1612"
    static let goldHex = "#e0b040"
    static let paperHex = "#f7f3ea"
}

enum BrandGeometry {
    static let canvas: CGFloat = 1024
    static let cornerRadiusRatio: CGFloat = 230 / canvas
    static let strokeWidthRatio: CGFloat = 28 / canvas
    static let ringRadiiRatios: [CGFloat] = [130 / canvas, 235 / canvas, 340 / canvas]
}

/// Half-annuli for the three concentric rings on either the left (`isLeft == true`)
/// or right (`isLeft == false`) half of the square canvas.
struct BrandHalfRingsShape: Shape {
    let isLeft: Bool
    var includeHalfPlane = false

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2
        let cx = rect.midX
        let cy = rect.midY
        let halfStroke = side * BrandGeometry.strokeWidthRatio / 2

        var path = Path()
        if includeHalfPlane {
            let halfRect = isLeft
                ? CGRect(x: originX, y: originY, width: side / 2, height: side)
                : CGRect(x: cx, y: originY, width: side / 2, height: side)
            path.addRect(halfRect)
        }

        for ratio in BrandGeometry.ringRadiiRatios {
            let r = side * ratio
            let outerR = r + halfStroke
            let innerR = max(0, r - halfStroke)
            var ring = Path()
            ring.move(to: CGPoint(x: cx, y: cy - outerR))
            ring.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: outerR,
                startAngle: .degrees(-90),
                endAngle: .degrees(90),
                clockwise: isLeft
            )
            ring.addLine(to: CGPoint(x: cx, y: cy + innerR))
            ring.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: innerR,
                startAngle: .degrees(90),
                endAngle: .degrees(-90),
                clockwise: !isLeft
            )
            ring.closeSubpath()
            path.addPath(ring)
        }
        return path
    }
}
