import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// When `true`, plays the one-shot assembly animation (split halves slide in,
    /// three rings draw from centre outward) unless Reduce Motion or UIKit
    /// animations are disabled.
    var assembles = false
    /// Called once when the assembly animation finishes.
    var onAssemblyFinished: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var halvesSettled = false
    @State private var hasStarted = false

    private var cornerRadius: CGFloat { size * BrandGeometry.cornerRadiusRatio }
    private var borderWidth: CGFloat { size * BrandGeometry.strokeWidthRatio }

    private var animationsEnabled: Bool {
        #if canImport(UIKit)
        UIView.areAnimationsEnabled
        #else
        true
        #endif
    }

    private var shouldAnimate: Bool {
        LogoAssemblyPolicy.shouldAnimateOnTermsGate(
            isFirstAppearance: assembles,
            reduceMotion: reduceMotion,
            animationsEnabled: animationsEnabled
        )
    }

    private var effectiveProgress: CGFloat {
        shouldAnimate ? progress : 1
    }

    private var effectiveHalvesSettled: Bool {
        shouldAnimate ? halvesSettled : true
    }

    var body: some View {
        let clipShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let slideOffset: CGFloat = effectiveHalvesSettled ? 0 : size
        ZStack {
            switch variant {
            case .color:
                HStack(spacing: 0) {
                    BrandPalette.ink
                        .offset(y: -slideOffset)
                    BrandPalette.gold
                        .offset(y: slideOffset)
                }
                BrandHalfRingsShape(isLeft: true, progress: effectiveProgress)
                    .fill(BrandPalette.gold)
                BrandHalfRingsShape(isLeft: false, progress: effectiveProgress)
                    .fill(BrandPalette.ink)
            case .monoInk:
                monoMark(foreground: BrandPalette.ink, clipShape: clipShape, progress: effectiveProgress)
            case .monoPaper:
                monoMark(foreground: BrandPalette.paper, clipShape: clipShape, progress: effectiveProgress)
            }
        }
        .frame(width: size, height: size)
        .clipShape(clipShape)
        .accessibilityHidden(true)
        .onAppear {
            guard shouldAnimate, !hasStarted else { return }
            hasStarted = true
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: BrandLogoAssemblyTiming.halvesDuration)) {
                halvesSettled = true
            }
            withAnimation(
                .linear(duration: BrandLogoAssemblyTiming.assemblyDuration),
                completionCriteria: .logicallyComplete
            ) {
                progress = 1
            } completion: {
                onAssemblyFinished?()
            }
        }
    }

    @ViewBuilder
    private func monoMark(foreground: Color, clipShape: RoundedRectangle, progress: CGFloat) -> some View {
        BrandHalfRingsShape(isLeft: true, includeHalfPlane: true, progress: progress)
            .fill(foreground, style: FillStyle(eoFill: true))
        BrandHalfRingsShape(isLeft: false, progress: progress)
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
