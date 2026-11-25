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

// MARK: - Logo assembly timing & policy

/// Timing and phase curves for the one-shot logo assembly animation
/// (`docs/wukongmind/design/unified-canvas/motion-proposal.html`, capped at ≤ 0.8 s).
enum BrandLogoAssemblyTiming {
    /// Total duration of the mark assembly (split halves + 3 staggered rings).
    static let assemblyDuration: Double = 0.62
    /// Duration of the ink/gold halves sliding into place (`0.26 s`, matching
    /// the proposal's `cubic-bezier(0.2, 0.8, 0.2, 1)` ease-out).
    static let halvesDuration: Double = 0.26
    /// Fade-out duration of the cold-start overlay after assembly settles.
    static let overlayFadeDuration: Double = 0.16
    /// Combined cold-start overlay budget (0.78 s ≤ 0.80 s).
    static var totalOverlayDuration: Double { assemblyDuration + overlayFadeDuration }

    private static let ringStarts: [CGFloat] = [0.28, 0.38, 0.48]
    private static let ringSpan: CGFloat = 0.52

    /// Cubic ease-out `1 - (1 - t)^3`, matching the snappy deceleration of
    /// `cubic-bezier(0.2, 0.8, 0.2, 1)` without overshoot.
    static func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        let inv = 1 - clamped
        return 1 - inv * inv * inv
    }

    /// Draw fraction (`0...1`) for ring `index` (0 = inner, 1 = middle, 2 = outer)
    /// at normalized assembly `progress` (`0...1`).
    static func ringProgress(index: Int, progress: CGFloat) -> CGFloat {
        guard progress < 1 else { return 1 }
        let start = index < ringStarts.count ? ringStarts[index] : ringStarts[ringStarts.count - 1]
        let local = min(max((progress - start) / ringSpan, 0), 1)
        return easeOut(local)
    }
}

/// Pure decision rules for when the logo assembly plays.
enum LogoAssemblyPolicy {
    /// Terms gate assembly plays once per process on first appearance, and never
    /// when Reduce Motion is enabled.
    static func shouldAnimateOnTermsGate(
        isFirstAppearance: Bool,
        reduceMotion: Bool,
        animationsEnabled: Bool = true
    ) -> Bool {
        isFirstAppearance && !reduceMotion && animationsEnabled
    }

    /// Cold-start overlay plays only when enabled in Settings, on a cold start,
    /// not on first run (where the Terms gate itself animates), and never with
    /// Reduce Motion or VoiceOver enabled.
    static func shouldShowLaunchOverlay(
        settingEnabled: Bool,
        isColdStart: Bool,
        needsTermsAcceptance: Bool,
        reduceMotion: Bool,
        voiceOverRunning: Bool,
        animationsEnabled: Bool = true
    ) -> Bool {
        settingEnabled
            && isColdStart
            && !needsTermsAcceptance
            && !reduceMotion
            && !voiceOverRunning
            && animationsEnabled
    }
}

/// Half-annuli for the three concentric rings on either the left (`isLeft == true`)
/// or right (`isLeft == false`) half of the square canvas. Animatable via `progress`
/// (`0...1`), drawing each ring clockwise from 12 o'clock (right half `0...0.5`,
/// left half `0.5...1`) from the centre ring outward.
struct BrandHalfRingsShape: Shape {
    let isLeft: Bool
    var includeHalfPlane = false
    var progress: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2
        let cx = rect.midX
        let cy = rect.midY
        let center = CGPoint(x: cx, y: cy)
        let halfStroke = side * BrandGeometry.strokeWidthRatio / 2

        var path = Path()
        if includeHalfPlane {
            let halfRect = isLeft
                ? CGRect(x: originX, y: originY, width: side / 2, height: side)
                : CGRect(x: cx, y: originY, width: side / 2, height: side)
            path.addRect(halfRect)
        }

        for (index, ratio) in BrandGeometry.ringRadiiRatios.enumerated() {
            let ringP = BrandLogoAssemblyTiming.ringProgress(index: index, progress: progress)
            let halfFraction: CGFloat = isLeft
                ? min(max((ringP - 0.5) * 2, 0), 1)
                : min(max(ringP * 2, 0), 1)
            guard halfFraction > 0.001 else { continue }

            let r = side * ratio
            let outerR = r + halfStroke
            let innerR = max(0, r - halfStroke)
            let startDeg: Double = isLeft ? 90 : -90
            let endDeg = startDeg + 180 * Double(halfFraction)
            let startRad = startDeg * .pi / 180
            let endRad = endDeg * .pi / 180

            var ring = Path()
            ring.move(to: CGPoint(
                x: cx + outerR * CGFloat(cos(startRad)),
                y: cy + outerR * CGFloat(sin(startRad))
            ))
            ring.addArc(
                center: center,
                radius: outerR,
                startAngle: .degrees(startDeg),
                endAngle: .degrees(endDeg),
                clockwise: false
            )
            ring.addLine(to: CGPoint(
                x: cx + innerR * CGFloat(cos(endRad)),
                y: cy + innerR * CGFloat(sin(endRad))
            ))
            ring.addArc(
                center: center,
                radius: innerR,
                startAngle: .degrees(endDeg),
                endAngle: .degrees(startDeg),
                clockwise: true
            )
            ring.closeSubpath()
            path.addPath(ring)
        }
        return path
    }
}
