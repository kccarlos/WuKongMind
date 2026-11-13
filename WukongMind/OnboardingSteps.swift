import SwiftUI

// The first-run pages (design-unified.md §5): 1 pick a model, 2 open a site.
// Step 3, the Agent's first run, is in OnboardingTry.swift. Each page scrolls on
// its own so large text and landscape phones never clip.

/// Scrolling, width-limited column shared by the pages.
struct OnboardingPage<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = DCTheme.spacingXL
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: alignment, spacing: spacing) {
                content()
            }
            .padding(.horizontal, DCTheme.spacingXL)
            .padding(.top, DCTheme.spacingM)
            .padding(.bottom, DCTheme.spacingXL)
            .frame(maxWidth: 540, alignment: Alignment(horizontal: alignment, vertical: .top))
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        #if DEBUG
        // `-dc-scroll-bottom`: start scrolled to the end (QA screenshots).
        .defaultScrollAnchor(OnboardingDebug.arguments.contains("-dc-scroll-bottom") ? .bottom : nil)
        #endif
    }
}

/// Large title + subtitle at the top of a page.
struct OnboardingHeader: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?
    var alignment: HorizontalAlignment = .leading
    var titleFont: Font = .title.weight(.bold)

    var body: some View {
        VStack(alignment: alignment, spacing: DCTheme.spacingS) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(DCTheme.goldInk)
            }
            Text(title)
                .font(titleFont)
                .foregroundStyle(DCTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Tinted rounded icon tile.
struct OnboardingIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 44
    var filled = false

    var body: some View {
        RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous)
            .fill(filled ? DCTheme.ink : tint.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(filled ? DCTheme.ground : tint)
            }
            .accessibilityHidden(true)
    }
}

/// Icon + title + detail row (features, privacy).
struct OnboardingFeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            OnboardingIconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 1. Pick a model

/// Step 1: the mark, then the providers for the Agent as radio rows (only
/// tool-calling models can be the Agent). The chosen row opens its key and
/// model fields; Continue tests them (OnboardingFlow).
struct OnboardingModelPage: View {
    @ObservedObject var app: AppModel
    @Binding var state: ProviderTestState
    @State private var choosesOther = false

    static let namedProviders: [AIProvider] = [.anthropic, .openRouter, .openAI]
    private let scope = ModelScope.role(.browserAgent)

    private var current: AIProvider { app.selection(for: .browserAgent).provider }
    private var othersSelected: Bool { choosesOther || !Self.namedProviders.contains(current) }

    var body: some View {
        OnboardingPage(alignment: .center, spacing: DCTheme.spacingL) {
            VStack(spacing: DCTheme.spacingS) {
                DCLogoView(size: 56, showsWordmark: true)
                    .padding(.bottom, DCTheme.spacingS)
                Text("An agent for any web page", comment: "First-run step 1 title")
                    .font(.title.weight(.bold))
                    .foregroundStyle(DCTheme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Pick a model for the Agent.", comment: "First-run step 1 subtitle")
                    .font(.body)
                    .foregroundStyle(DCTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                ForEach(Self.namedProviders, id: \.self) { provider in
                    row(provider)
                    Divider().overlay(DCTheme.hairline)
                }
                otherRow
            }
            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous).strokeBorder(DCTheme.hairline)
            }
            Label {
                Text("Keys stay in the Keychain", comment: "First-run step 1 footnote")
            } icon: {
                Image(systemName: "key.fill")
            }
            .font(.footnote)
            .foregroundStyle(DCTheme.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DCTheme.spacingS)
        }
        .onAppear {
            // The first provider is chosen, as the design draws it.
            if app.settings.browserAgentModel == nil { app.selectProvider(Self.namedProviders[0], for: scope) }
        }
    }

    private func row(_ provider: AIProvider) -> some View {
        let isOn = !othersSelected && current == provider
        return VStack(spacing: 0) {
            radioRow(title: provider.displayName, isOn: isOn, id: "onboardingProvider-\(provider.rawValue)") {
                choosesOther = false
                state = .idle
                app.selectProvider(provider, for: scope)
            }
            if isOn { form }
        }
    }

    private var otherRow: some View {
        VStack(spacing: 0) {
            radioRow(
                title: String(localized: "Other provider…", comment: "First-run step 1: the row that opens every other provider"),
                isOn: othersSelected,
                id: "onboardingProvider-other"
            ) {
                guard !othersSelected else { return }
                choosesOther = true
                state = .idle
            }
            if othersSelected {
                VStack(alignment: .leading, spacing: DCTheme.spacingM) {
                    ProviderMenu(app: app, scope: scope) {
                        HStack(spacing: DCTheme.spacingM) {
                            Text(Self.namedProviders.contains(current) ? String(localized: "Choose a provider", comment: "First-run step 1: the provider menu before one is chosen") : current.displayName)
                                .font(.body)
                                .foregroundStyle(DCTheme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DCTheme.inkFaint)
                        }
                        .padding(.horizontal, DCTheme.spacingM)
                        .frame(minHeight: DCTheme.controlHeight)
                        .background(DCTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !Self.namedProviders.contains(current) { form }
                }
                .padding(.leading, 48)
                .padding(.trailing, DCTheme.spacingL)
                .padding(.bottom, DCTheme.spacingM)
            }
        }
    }

    /// The key and model fields of the chosen provider.
    private var form: some View {
        ProviderSetupForm(app: app, scope: scope, state: $state, isCompact: true)
            .padding(.leading, Self.namedProviders.contains(current) ? 48 : 0)
            .padding(.trailing, Self.namedProviders.contains(current) ? DCTheme.spacingL : 0)
            .padding(.bottom, DCTheme.spacingM)
    }

    private func radioRow(title: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            DCHaptics.selection()
            action()
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                Circle()
                    .strokeBorder(isOn ? DCTheme.gold : DCTheme.borderStrong, lineWidth: isOn ? 7 : 1.5)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.body)
                    .foregroundStyle(DCTheme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DCTheme.spacingL)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

// MARK: 2. Open a site

/// Step 2: any address, or one of the suggested sites (no forum badge; each
/// says what the site is about). `selectedSiteURL` is what Open opens when the
/// address field is empty.
struct OnboardingSitePage: View {
    @Binding var address: String
    @Binding var selectedSiteURL: String?
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    static var suggestions: [SuggestedForum] { Array(AppModel.onboardingSuggestions().prefix(4)) }

    var body: some View {
        OnboardingPage(spacing: DCTheme.spacingXL) {
            VStack(spacing: DCTheme.spacingS) {
                Text("Open a site", comment: "First-run step 2 title")
                    .font(.title.weight(.bold))
                    .foregroundStyle(DCTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Any address works.", comment: "First-run step 2 subtitle")
                    .font(.body)
                    .foregroundStyle(DCTheme.inkMuted)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            addressField
            VStack(alignment: .leading, spacing: DCTheme.spacingS) {
                Text("Suggested", comment: "First-run step 2: the list of suggested sites")
                    .font(.footnote)
                    .textCase(.uppercase)
                    .foregroundStyle(DCTheme.inkMuted)
                    .padding(.horizontal, DCTheme.spacingL)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    let rows = Self.suggestions
                    ForEach(Array(rows.enumerated()), id: \.element.siteURL) { index, site in
                        if index > 0 { Divider().overlay(DCTheme.hairline).padding(.leading, 68) }
                        siteRow(site)
                    }
                }
                .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous).strokeBorder(DCTheme.hairline)
                }
            }
        }
        .onChange(of: address) {
            if !address.isEmpty { selectedSiteURL = nil }
        }
        #if DEBUG
        .task {
            if OnboardingDebug.arguments.contains("-dc-focus") {
                try? await Task.sleep(for: .milliseconds(600))
                focused = true
            }
        }
        #endif
    }

    private var addressField: some View {
        HStack(spacing: DCTheme.spacingS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DCTheme.inkFaint)
                .accessibilityHidden(true)
            TextField(text: $address, prompt: Text("Search or enter address", comment: "Home address field placeholder").foregroundStyle(DCTheme.inkFaint)) {
                Text("Address", comment: "Accessibility label of Home's address field")
            }
            .keyboardType(.webSearch)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.go)
            .focused($focused)
            .onSubmit {
                focused = false
                onSubmit()
            }
            .foregroundStyle(DCTheme.ink)
            .accessibilityIdentifier("onboardingSiteAddress")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                .strokeBorder(focused ? DCTheme.goldInk : DCTheme.hairline, lineWidth: focused ? DCTheme.ringWidth : DCTheme.hairlineWidth)
        }
    }

    private func siteRow(_ site: SuggestedForum) -> some View {
        let isOn = selectedSiteURL == site.siteURL
        return Button {
            DCHaptics.selection()
            focused = false
            address = ""
            selectedSiteURL = site.siteURL
        } label: {
            HStack(spacing: DCTheme.spacingM) {
                ForumIcon(suggested: site, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DCTheme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(site.description)
                        .font(.footnote)
                        .foregroundStyle(DCTheme.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: DCTheme.spacingS)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(DCTheme.goldInk)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DCTheme.spacingL)
            .padding(.vertical, DCTheme.spacingM)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("onboardingSite-\(site.host)")
    }
}

/// Forum icon, falling back to a colored letter tile (the walkthrough passes
/// no `iconURL`: forums' logos aren't shown there).
struct OnboardingForumIcon: View {
    let siteURL: String
    let name: String
    var iconURL: URL?
    var size: CGFloat = 36

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            shape.fill(DCTheme.forumTint(for: siteURL))
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .background(Color.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

// MARK: Share from Safari or Chrome

/// The Share how-to page (Home, Settings › Help, the last step). The share
/// extension's four actions are listed as `ShareSheetView` has them.
struct ShareHowToGuide: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: DCTheme.spacingL) {
            ShareSheetIllustration()
            VStack(alignment: .leading, spacing: DCTheme.spacingM) {
                ShareStepRow(number: 1, symbol: "square.and.arrow.up", text: "Open a forum topic in Safari or Chrome and tap **Share**. In Chrome, tap **⋯**, then **Share…**")
                ShareStepRow(number: 2, symbol: "switch.2", text: "First time only: swipe the row of apps to the end, tap **More**, turn on **WukongMind** and add it to Favorites.")
                ShareStepRow(number: 3, symbol: "hand.tap.fill", text: "Tap **WukongMind**, then pick what you want:")
            }
            ShareActionsIllustration()
                .padding(.leading, 40)
            ShareStepRow(number: 4, symbol: "arrow.up.forward.app", text: "Open WukongMind. Your page is waiting there, and what you picked starts.")
            Text("You only need to turn it on once. After that it appears in every app’s share sheet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openURL(AppModel.shareTryURL)
            } label: {
                Label("Try It in Safari", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCActionButtonStyle(prominent: false))
            .accessibilityIdentifier("shareHowToTrySafari")
        }
    }
}

/// The Share how-to as a sheet (Home card, last walkthrough step).
struct ShareHowToSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DCTheme.spacingL) {
                    OnboardingHeader(
                        eyebrow: String(localized: "Tip"),
                        title: String(localized: "Share from Safari or Chrome"),
                        subtitle: String(localized: "Reading a forum in another browser? Send the page to WukongMind in a couple of taps.")
                    )
                    ShareHowToGuide()
                    Button("Done", action: onDone)
                        .buttonStyle(DCPrimaryButtonStyle())
                        .accessibilityIdentifier("shareHowToDone")
                }
                .padding(DCTheme.spacingL)
                .frame(maxWidth: DCTheme.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(DCTheme.pageBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ShareStepRow: View {
    let number: Int
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: DCTheme.spacingM) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(DCTheme.onGold)
                .frame(width: 28, height: 28)
                .background(DCTheme.gold, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// SF Symbols mock of the iOS share sheet with WukongMind highlighted.
struct ShareSheetIllustration: View {
    var body: some View {
        VStack(spacing: DCTheme.spacingM) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
            HStack(spacing: DCTheme.spacingM) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DCTheme.goldWash)
                    .frame(width: 38, height: 38)
                    .overlay { Image(systemName: "safari").foregroundStyle(DCTheme.goldInk) }
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.7)).frame(width: 150, height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.4)).frame(width: 100, height: 7)
                }
                Spacer()
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                appIcon(symbol: "message.fill", tint: .green, label: String(localized: "Messages", comment: "Name of Apple's Messages app, as shown in the iOS share sheet"))
                appIcon(symbol: "envelope.fill", tint: .blue, label: String(localized: "Mail", comment: "Name of Apple's Mail app, as shown in the iOS share sheet"))
                appIcon(symbol: "note.text", tint: .orange, label: String(localized: "Notes", comment: "Name of Apple's Notes app, as shown in the iOS share sheet"))
                appIcon
                appIcon(symbol: "ellipsis", tint: .gray, label: String(localized: "More", comment: "The More button at the end of the app row in the iOS share sheet"), plain: true)
            }
        }
        .padding(DCTheme.spacingL)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DCTheme.border)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        .accessibilityElement()
        .accessibilityLabel("Illustration: the share sheet with WukongMind in the row of apps, next to More.")
    }

    private var appIcon: some View {
        VStack(spacing: 6) {
            BrandMark(size: 52)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DCTheme.gold, lineWidth: 2.5)
                }
            Text("WukongMind")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DCTheme.goldInk)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func appIcon(symbol: String, tint: Color, label: String, plain: Bool = false) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(plain ? Color.secondary.opacity(0.15) : tint)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(plain ? Color.primary : Color.white)
                }
                .padding(3)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The four actions the WukongMind share sheet offers.
struct ShareActionsIllustration: View {
    private let actions: [(String, String, Color)] = [
        // The share extension's buttons (same wording as WukongMindShare).
        (String(localized: "Summarize"), "sparkles", .indigo),
        (String(localized: "Chat about it"), "bubble.left.and.bubble.right.fill", .blue),
        (String(localized: "Ask the forum"), "text.magnifyingglass", .teal),
        (String(localized: "Just open"), "safari.fill", .gray)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions, id: \.0) { title, symbol, tint in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DCTheme.ink)
                        .frame(width: 26, height: 26)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DCTheme.ground)
                        }
                    Text(title).font(.subheadline.weight(.medium))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
