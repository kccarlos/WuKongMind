import SwiftUI
import UIKit

// MARK: - Dynamic Color Builders

extension Color {
    /// Dynamic sRGB colour with separate light and dark hex values, plus optional
    /// Increase Contrast overrides (`accessibilityContrast == .high`).
    init(
        light: UInt32,
        dark: UInt32,
        highContrastLight: UInt32? = nil,
        highContrastDark: UInt32? = nil,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) {
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHigh = traits.accessibilityContrast == .high
            let hex: UInt32
            let alpha: CGFloat
            if isDark {
                hex = (isHigh ? highContrastDark : nil) ?? dark
                alpha = darkAlpha
            } else {
                hex = (isHigh ? highContrastLight : nil) ?? light
                alpha = lightAlpha
            }
            return UIColor(hex: hex, alpha: alpha)
        })
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// `#RRGGBB` for injected page CSS (such as cited-post highlights in `BrowseBridge`).
    func cssHex(dark: Bool, highContrast: Bool) -> String {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: highContrast ? .high : .normal)
        ])
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - WukongMind Design System Tokens

enum DCTheme {
    // Surfaces — warm paper in light, lacquer black in dark (never pure white or pure black)
    static let ground = Color(light: 0xF7F3EA, dark: 0x14110E)
    static let surface = Color(light: 0xFFFDF8, dark: 0x1F1B16)
    static let surfaceRaised = Color(light: 0xEFE9DC, dark: 0x2A251E)

    // Ink — reading and structure
    static let ink = Color(light: 0x1A1612, dark: 0xF4EEE2)
    static let inkMuted = Color(light: 0x5F574C, dark: 0xB3A998)
    /// Only on `ground` and `surface` (4.5:1+ there).
    static let inkFaint = Color(light: 0x756C5F, dark: 0x8F8676)

    // Borders — Increase Contrast switches `hairline` to `borderStrong`
    static let borderStrong = Color(light: 0x8C8375, dark: 0x7D7567)
    static let hairline = Color(uiColor: UIColor { traits in
        let isDark = traits.userInterfaceStyle == .dark
        if traits.accessibilityContrast == .high {
            return UIColor(hex: isDark ? 0x7D7567 : 0x8C8375)
        }
        return isDark
            ? UIColor(hex: 0xF4EEE2, alpha: 0.16)
            : UIColor(hex: 0x1A1612, alpha: 0.14)
    })

    // Gold — the Agent and the one primary action
    static let gold = Color(light: 0xB07F0C, dark: 0xE0B040)
    /// Text/glyphs on a `gold` fill (always dark; white on gold fails contrast).
    static let onGold = Color(light: 0x1A1612, dark: 0x1A1612)
    /// Gold as text or icon on `ground`, `surface`, or `goldWash`.
    static let goldInk = Color(light: 0x8A6200, dark: 0xE8BD55)
    static let goldWash = Color(light: 0xF6ECD0, dark: 0x3A2F14)

    // Jade — content that came from a website (summaries, citations, source links)
    static let jade = Color(light: 0x1F6F66, dark: 0x6FD0C2)
    static let jadeWash = Color(light: 0xDCEFEB, dark: 0x12302C)

    // Cinnabar — stop, delete, error only
    static let cinnabar = Color(light: 0xB3321F, dark: 0xFF7A5C)
    static let onCinnabar = Color(light: 0xFFFFFF, dark: 0x1A1612)
    static let cinnabarWash = Color(light: 0xF9E1DA, dark: 0x3D1A12)
    static let danger = cinnabar

    // States — always paired with an icon + word
    static let success = Color(light: 0x356F1B, dark: 0x8FD66B)
    static let warning = Color(light: 0xA34A08, dark: 0xFFB070)

    // Overlay scrim
    static let scrim = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: 0x000000, alpha: 0.50)
            : UIColor(hex: 0x14110E, alpha: 0.40)
    })

    // Spacing (4pt base)
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32

    // Radii
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 10
    static let radiusLg: CGFloat = 14
    static let radiusSheet: CGFloat = 28
    static let radiusFull: CGFloat = 999

    // Borders
    static let hairlineWidth: CGFloat = 1
    static let ringWidth: CGFloat = 2

    // Shadows (only for floating layers: assistant panel, popovers, browser bar)
    struct ShadowSpec {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// `0 -8px 30px rgba(20,17,14,0.16)`
    static let shadowPanel = ShadowSpec(
        color: Color(hex: 0x14110E, opacity: 0.16),
        radius: 15,
        x: 0,
        y: -8
    )

    /// `0 12px 40px rgba(20,17,14,0.22)`
    static let shadowPop = ShadowSpec(
        color: Color(hex: 0x14110E, opacity: 0.22),
        radius: 20,
        x: 0,
        y: 12
    )

    // MARK: Role mappings (so existing screens pick up the new look)

    static let pageBackground = ground
    static let raisedSurface = surfaceRaised
    static let toolbar = surface
    static let border = hairline

    static let agentTint = goldInk
    static let summaryTint = jade
    static let chatTint = jade
    static let citationText = jade
    static let postHighlightBackground = jadeWash
    static let postHighlightStroke = jade
    static func postHighlightStrokeWidth(highContrast: Bool) -> CGFloat { highContrast ? 3 : 2 }

    static let newRepliesBadgeText = goldInk
    static let newRepliesBadgeBackground = goldWash

    static let spacingXS = space1
    static let spacingS = space2
    static let spacingM = space3
    static let spacingL = space4
    static let spacingXL = space6
    static let spacingXXL = space8

    static let panelMinimumWidth: CGFloat = 360
    static let panelIdealWidth: CGFloat = 470
    static let panelMaximumWidth: CGFloat = 560
    static let splitLayoutMinimumWidth: CGFloat = 850
    static let cardCornerRadius = radiusLg
    static let controlCornerRadius = radiusMd
    static let controlHeight: CGFloat = 44
    static let contentMaxWidth: CGFloat = 640

    /// Process-wide UIKit appearance defaults for controls hosted inside `Form`/`List`.
    static func applyAppearance() {
        UISwitch.appearance().onTintColor = UIColor(gold)
    }
}

// MARK: - Type Styles (Dynamic Type)

enum DCType {
    static let largeTitle = Font.largeTitle.weight(.bold)
    static let title = Font.title2.weight(.bold)
    static let headline = Font.headline
    static let body = Font.body
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption.weight(.semibold)
    static let code = Font.footnote.monospaced()
}

// MARK: - Motion & Haptics

enum DCMotion {
    /// Short functional transitions (≤ 250ms) on standard curves; no decorative bounces.
    static let quick = Animation.easeOut(duration: 0.18)
    static let smooth = Animation.snappy(duration: 0.24)
    static let spring = Animation.snappy(duration: 0.24)

    /// `animation`, or a quick fade when Reduce Motion is enabled.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation = DCMotion.smooth) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }

    /// Slide + fade, or a plain fade with Reduce Motion.
    static func slide(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// Fade transition for swapping whole screens (no decorative scale/zoom).
    static func screen(reduceMotion: Bool) -> AnyTransition {
        .opacity
    }
}

enum DCHaptics {
    @MainActor static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @MainActor static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Card, Shadow & Focus Modifiers

struct DCCardModifier: ViewModifier {
    var tint: Color = .clear

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous)
        content
            .padding(DCTheme.space4)
            .background {
                ZStack {
                    shape.fill(DCTheme.surface)
                    if tint != .clear {
                        shape.fill(tint.opacity(0.08))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    tint == .clear ? DCTheme.hairline : tint.opacity(0.45),
                    lineWidth: DCTheme.hairlineWidth
                )
            }
    }
}

extension View {
    func dcCard(tint: Color = .clear) -> some View {
        modifier(DCCardModifier(tint: tint))
    }

    func dcShadowPanel() -> some View {
        let s = DCTheme.shadowPanel
        return shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }

    func dcShadowPop() -> some View {
        let s = DCTheme.shadowPop
        return shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }

    func dcFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = DCTheme.radiusMd) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DCTheme.goldInk, lineWidth: DCTheme.ringWidth)
            }
        }
    }

    /// Decorative symbol bounce removed per design system motion rules.
    func dcStateBounce<Value: Equatable>(_ state: Value) -> some View {
        self
    }

    /// Warm `ground` background for grouped `Form` / `List` screens.
    func dcGroupedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(DCTheme.ground)
    }
}

// MARK: - Existing Shared Styles Mapped to Design System

/// Squared seal badge (`radiusSm`, never `Capsule()`), preserving `DCPill`'s call sites.
struct DCPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = DCTheme.inkMuted

    var body: some View {
        HStack(spacing: DCTheme.space1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(DCType.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, DCTheme.space2)
        .padding(.vertical, DCTheme.space1)
        .frame(minHeight: 24)
        .background(
            tint.opacity(0.14),
            in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
        )
    }
}

/// Compact squared status seal for browser bar / inline status.
struct DCStatusChip: View {
    let text: String?
    var systemImage: String?
    var tint: Color = DCTheme.inkMuted

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            if let text {
                Text(text).lineLimit(1)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            tint.opacity(0.14),
            in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
        )
        .fixedSize()
    }
}

/// Primary full-width gold button (`gold` fill, `onGold` text, `radiusMd`).
struct DCPrimaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 50
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DCType.headline)
            .foregroundStyle(isEnabled ? DCTheme.onGold : DCTheme.inkFaint)
            .padding(.horizontal, DCTheme.space4)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(
                isEnabled ? DCTheme.gold : DCTheme.surfaceRaised,
                in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Compact action button: `.primary` (`gold` + `onGold`) when `prominent`, `.secondary` (`borderStrong` + `ink`) otherwise.
struct DCActionButtonStyle: ButtonStyle {
    var prominent = false
    var minHeight: CGFloat = DCTheme.controlHeight
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: minHeight)
            .background(background, in: shape)
            .overlay {
                if !prominent && isEnabled {
                    shape.strokeBorder(DCTheme.borderStrong, lineWidth: DCTheme.hairlineWidth)
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foreground: Color {
        if !isEnabled { return DCTheme.inkFaint }
        return prominent ? DCTheme.onGold : DCTheme.ink
    }

    private var background: Color {
        if !isEnabled { return DCTheme.surfaceRaised }
        return prominent ? DCTheme.gold : .clear
    }
}

/// Toolbar / inline icon button with a guaranteed 44×44pt hit target and no bounce.
struct DCIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: DCTheme.controlHeight, minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Section header used on scrolling pages.
struct DCSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DCType.headline)
                .foregroundStyle(DCTheme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(DCType.subheadline)
                    .foregroundStyle(DCTheme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Forum Identity (unchanged 8-colour site tile palette)

extension DCTheme {
    static let forumTileIcon: CGFloat = 56
    static let forumIconCornerRatio: CGFloat = 0.26

    static let forumPalette: [Color] = [
        Color(light: 0x3A5BE0, dark: 0x6F88FF),
        Color(light: 0x8E2DB5, dark: 0xC77DEB),
        Color(light: 0x0E8A7E, dark: 0x3CC4B3),
        Color(light: 0xC2410C, dark: 0xFB8A4C),
        Color(light: 0xB42363, dark: 0xF06A9F),
        Color(light: 0x2F7A2F, dark: 0x6BCB6B),
        Color(light: 0x5B4BC4, dark: 0x9C8FFF),
        Color(light: 0x9A6700, dark: 0xE7B43A)
    ]

    static func forumTint(for siteURL: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in ForumSite.host(of: siteURL).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return forumPalette[Int(hash % UInt32(forumPalette.count))]
    }
}

// MARK: - Keyboard Visibility & Sticky Footer

private struct KeyboardVisibilityModifier: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isVisible = false
            }
    }
}

extension View {
    func dcKeyboardVisible(_ isVisible: Binding<Bool>) -> some View {
        modifier(KeyboardVisibilityModifier(isVisible: isVisible))
    }

    /// Sticky bottom footer on warm `ground` with a crisp hairline top separator (no gradient).
    func dcStickyFooter() -> some View {
        background {
            DCTheme.ground
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(DCTheme.hairline)
                        .frame(height: DCTheme.hairlineWidth)
                }
                .ignoresSafeArea()
        }
    }
}

// MARK: - Design System Components (Button, Seal, Switch, ListRow, AgentRing, Logo & Mascot)

enum DCButtonRole: Sendable {
    /// Filled `gold` with `onGold` text — at most one per view or card.
    case primary
    /// Outlined in `borderStrong` with `ink` text.
    case secondary
    /// Text-only in `goldInk` (`Cancel`, `Skip`, `Later`, `Edit`).
    case quiet
    /// Filled `cinnabar` with `onCinnabar` text (`Stop` while Agent is running).
    case destructive
    /// Outlined in `borderStrong` with `danger` text (`Delete` in a sheet/row).
    case destructiveOutline
}

struct DCButtonStyle: ButtonStyle {
    var role: DCButtonRole = .primary
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
        configuration.label
            .font(DCType.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, role == .quiet ? DCTheme.space3 : DCTheme.space4)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: DCTheme.controlHeight)
            .background(background, in: shape)
            .overlay {
                if showsBorder {
                    shape.strokeBorder(DCTheme.borderStrong, lineWidth: DCTheme.hairlineWidth)
                }
            }
            .dcFocusRing(isFocused, cornerRadius: DCTheme.radiusMd)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return DCTheme.inkFaint }
        return switch role {
        case .primary: DCTheme.onGold
        case .secondary: DCTheme.ink
        case .quiet: DCTheme.goldInk
        case .destructive: DCTheme.onCinnabar
        case .destructiveOutline: DCTheme.danger
        }
    }

    private var background: Color {
        guard isEnabled else {
            return role == .quiet ? .clear : DCTheme.surfaceRaised
        }
        return switch role {
        case .primary: DCTheme.gold
        case .secondary, .quiet, .destructiveOutline: .clear
        case .destructive: DCTheme.cinnabar
        }
    }

    private var showsBorder: Bool {
        isEnabled && (role == .secondary || role == .destructiveOutline)
    }
}

enum DCSealState: Sendable {
    case ready
    case attention
    case error
    case neutral

    var defaultSymbol: String {
        switch self {
        case .ready: "checkmark"
        case .attention: "exclamationmark.triangle"
        case .error: "xmark.circle"
        case .neutral: "minus"
        }
    }

    var foreground: Color {
        switch self {
        case .ready: DCTheme.success
        case .attention: DCTheme.warning
        case .error: DCTheme.danger
        case .neutral: DCTheme.inkMuted
        }
    }
}

enum DCSealVariant: Sendable {
    /// `ink` fill, `ground` text (high-contrast counts, active script count on Agent button).
    case ink
    /// `borderStrong` 1pt outline, `ink` text (model seal, neutral filter).
    case outline
    /// `goldWash` fill, `goldInk` text ("Saved" note, Agent badges).
    case gold
    /// `jadeWash` fill, `jade` text (website citations, forum/thread tags).
    case jade
    /// Icon + word in `success`, `warning`, `danger`, or `inkMuted` with no background.
    case state(DCSealState)
}

struct DCSeal: View {
    let text: String
    var variant: DCSealVariant = .outline
    var systemImage: String?
    var showsAgentRing = false
    var showsChevron = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
        HStack(spacing: DCTheme.space1) {
            if showsAgentRing {
                DCAgentRing(size: 11, lineWidth: 1.6)
            } else if let resolvedSymbol {
                Image(systemName: resolvedSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(foreground.opacity(0.8))
                    .accessibilityHidden(true)
            }
        }
        .font(DCType.caption)
        .foregroundStyle(foreground)
        .padding(.horizontal, isBareState ? 0 : DCTheme.space2)
        .padding(.vertical, isBareState ? 0 : DCTheme.space1)
        .frame(minHeight: 24)
        .background(background, in: shape)
        .overlay {
            if case .outline = variant {
                shape.strokeBorder(DCTheme.borderStrong, lineWidth: DCTheme.hairlineWidth)
            }
        }
    }

    private var isBareState: Bool {
        if case .state = variant { return true }
        return false
    }

    private var resolvedSymbol: String? {
        if let systemImage { return systemImage }
        if case .state(let state) = variant { return state.defaultSymbol }
        return nil
    }

    private var foreground: Color {
        switch variant {
        case .ink: DCTheme.ground
        case .outline: DCTheme.ink
        case .gold: DCTheme.goldInk
        case .jade: DCTheme.jade
        case .state(let state): state.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .ink: DCTheme.ink
        case .outline: DCTheme.surface
        case .gold: DCTheme.goldWash
        case .jade: DCTheme.jadeWash
        case .state: .clear
        }
    }
}

/// Interactive seal button with a 44pt touch target and trailing disclosure chevron.
struct DCSealButton: View {
    let text: String
    var variant: DCSealVariant = .outline
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button {
            DCHaptics.tap()
            action()
        } label: {
            DCSeal(
                text: text,
                variant: variant,
                systemImage: systemImage,
                showsChevron: true
            )
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DCSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    static let trackWidth: CGFloat = 51
    static let trackHeight: CGFloat = 31
    static let knobSize: CGFloat = 25
    static let knobInset: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        Button {
            DCHaptics.selection()
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: DCTheme.space3) {
                configuration.label
                    .foregroundStyle(DCTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                track(isOn: configuration.isOn)
            }
            .frame(minHeight: DCTheme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isButton)
    }

    private func track(isOn: Bool) -> some View {
        let offset = (Self.trackWidth - Self.knobSize) / 2 - Self.knobInset
        return ZStack {
            Capsule()
                .fill(isOn ? DCTheme.gold : DCTheme.surface)
                .overlay {
                    if !isOn {
                        Capsule()
                            .strokeBorder(DCTheme.borderStrong, lineWidth: DCTheme.hairlineWidth)
                    }
                }
            Circle()
                .fill(isOn ? DCTheme.onGold : DCTheme.inkMuted)
                .frame(width: Self.knobSize, height: Self.knobSize)
                .offset(x: isOn ? offset : -offset)
        }
        .frame(width: Self.trackWidth, height: Self.trackHeight)
        .accessibilityHidden(true)
    }
}

struct DCListIconTile: View {
    enum Kind: Sendable {
        case ink(symbol: String)
        case agent
    }

    let kind: Kind
    var size: CGFloat = 29

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
        ZStack {
            switch kind {
            case .ink(let symbol):
                shape.fill(DCTheme.ink)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.50, weight: .semibold))
                    .foregroundStyle(DCTheme.ground)
            case .agent:
                shape.fill(DCTheme.gold)
                Circle()
                    .strokeBorder(DCTheme.onGold, lineWidth: 2)
                    .frame(width: size * 0.52, height: size * 0.52)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DCListRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showsChevron = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        icon: DCListIconTile.Kind? = nil,
        showsChevron: Bool = false
    ) where Leading == AnyView, Trailing == AnyView {
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.leading = {
            if let icon {
                AnyView(DCListIconTile(kind: icon))
            } else {
                AnyView(EmptyView())
            }
        }
        self.trailing = {
            if let value, !value.isEmpty {
                AnyView(
                    Text(value)
                        .font(DCType.body)
                        .foregroundStyle(DCTheme.inkMuted)
                        .lineLimit(1)
                )
            } else {
                AnyView(EmptyView())
            }
        }
    }

    init(
        title: String,
        subtitle: String? = nil,
        showsChevron: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: DCTheme.space3) {
            leading()
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DCTheme.space1) {
                    titleStack
                    trailing()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                titleStack
                Spacer(minLength: DCTheme.space2)
                trailing()
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DCTheme.inkFaint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, DCTheme.space1)
        .frame(minHeight: DCTheme.controlHeight)
        .listRowBackground(DCTheme.surface)
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DCType.body)
                .foregroundStyle(DCTheme.ink)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DCType.footnote)
                    .foregroundStyle(DCTheme.inkMuted)
            }
        }
    }
}

/// The signature gold band: an open circle with a `gold` stroke and nothing inside.
/// Turns continuously (~1.1s linear revolution) only while the Agent is working, and
/// stands still when Reduce Motion is enabled.
struct DCAgentRing: View {
    var size: CGFloat = 22
    var lineWidth: CGFloat = DCTheme.ringWidth
    var isTurning = false
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let turnPeriod: TimeInterval = 1.1

    var body: some View {
        let strokeColor = isEnabled ? DCTheme.gold : DCTheme.inkFaint
        Group {
            if isTurning && !reduceMotion {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.turnPeriod) / Self.turnPeriod
                    ZStack {
                        Circle()
                            .strokeBorder(DCTheme.hairline, lineWidth: lineWidth)
                        Circle()
                            .inset(by: lineWidth / 2)
                            .trim(from: 0, to: 0.74)
                            .stroke(
                                strokeColor,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(phase * 360 - 90))
                    }
                }
            } else {
                Circle()
                    .strokeBorder(strokeColor, lineWidth: lineWidth)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum DCLogoVariant: String, CaseIterable, Sendable {
    case mark = "LogoMark"
    case monoInk = "LogoMarkMonoInk"
    case monoPaper = "LogoMarkMonoPaper"

    var assetName: String { rawValue }
}

/// Renders the WukongMind vector logo mark from `Assets.xcassets`, optionally paired
/// with `"WukongMind"` in semibold `ink` per `assets/Logo/README.md`.
struct DCLogoView: View {
    var variant: DCLogoVariant = .mark
    var size: CGFloat = 48
    var showsWordmark = false

    static let minimumSize: CGFloat = 24

    private var clampedSize: CGFloat {
        max(Self.minimumSize, size)
    }

    var body: some View {
        HStack(spacing: max(DCTheme.space2, round(clampedSize * 0.28))) {
            Image(variant.assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: clampedSize, height: clampedSize)
                .accessibilityHidden(true)
            if showsWordmark {
                Text(verbatim: "WukongMind")
                    .font(.system(size: round(clampedSize * 0.50), weight: .semibold))
                    .foregroundStyle(variant == .monoPaper ? BrandPalette.paper : DCTheme.ink)
            }
        }
        .accessibilityElement(children: showsWordmark ? .combine : .ignore)
        .accessibilityHidden(!showsWordmark)
    }
}

enum DCMascotPose: String, CaseIterable, Sendable {
    /// Empty panel, greeting on Home (`MascotWave`).
    case wave = "MascotWave"
    /// Empty state before the first question, waiting for input (`MascotThink`).
    case think = "MascotThink"
    /// Working on a multi-step task (`MascotRun`).
    case run = "MascotRun"
    /// No results, nothing saved for this site (`MascotSearch`).
    case search = "MascotSearch"
    /// Onboarding done, first script saved (`MascotCheer`).
    case cheer = "MascotCheer"

    var assetName: String { rawValue }
}

/// Renders one of the 5 still vector mascot poses from `Assets.xcassets`.
/// Enforces the 40pt minimum size from `assets/Mascot/README.md` and never animates.
struct DCMascotView: View {
    let pose: DCMascotPose
    var size: CGFloat = 96
    var accessibilityLabel: String?

    static let minimumSize: CGFloat = 40

    private var clampedSize: CGFloat {
        max(Self.minimumSize, size)
    }

    var body: some View {
        let image = Image(pose.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: clampedSize, height: clampedSize)
        if let accessibilityLabel {
            image.accessibilityLabel(Text(accessibilityLabel))
        } else {
            image.accessibilityHidden(true)
        }
    }
}
