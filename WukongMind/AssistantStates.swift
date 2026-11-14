import SwiftUI

// The Assistant's page-state cards
// and the small pieces the assistant screens share: forum icon, mode
// switcher, provider setup card, progress bar, typing indicator.

extension AssistantMode {
    /// Visible title; the accessibility tree uses `accessibilityTitle`.
    var title: String {
        switch self {
        case .summary: String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")
        case .agent: String(localized: "Ask the forum", comment: "Assistant mode: the research agent that searches the whole forum")
        case .browserAgent:
            String(
                localized: "assistantMode.browserAgent",
                defaultValue: "Agent",
                comment: "Browser agent mode title in the AI drawer header and mode switcher"
            )
        }
    }

    /// The name in the accessibility tree ("Summary", "Chat", "Agent" in
    /// English, as the UI tests expect), translated for VoiceOver.
    var accessibilityTitle: String {
        switch self {
        case .summary: String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")
        case .agent: String(localized: "Agent", comment: "VoiceOver name of the “Ask the forum” assistant mode (the research agent)")
        case .browserAgent: title
        }
    }

    /// Used when the full titles don't fit the mode switcher.
    var shortTitle: String {
        switch self {
        case .summary: String(localized: "Summary", comment: "Assistant mode: the topic's AI summary")
        case .agent: String(localized: "Ask", comment: "Short form of the “Ask the forum” assistant mode, for narrow switchers")
        case .browserAgent: title
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.alignleft"
        case .agent: "sparkle.magnifyingglass"
        case .browserAgent: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .summary: DCTheme.summaryTint
        case .agent, .browserAgent: DCTheme.agentTint
        }
    }
}

// MARK: - Forum icon

/// A forum's favicon, or a colored monogram when it has none (or offline).
struct AssistantForumIcon: View {
    let siteURL: String?
    let name: String
    var iconURL: URL?
    var size: CGFloat = 28

    init(forum: Forum?, size: CGFloat = 28) {
        siteURL = forum?.siteURL
        name = forum?.displayName ?? "WukongMind"
        iconURL = ForumIconPolicy.loadsRemoteIcons ? forum?.iconURL : nil
        self.size = size
    }

    private var tint: Color {
        siteURL.map(DCTheme.forumTint(for:)) ?? DCTheme.goldInk
    }

    private var monogram: String {
        let letters = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return letters.first.map { String($0).uppercased() } ?? "D"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        ZStack {
            if siteURL == nil {
                BrandMark(size: size)
            } else {
                shape.fill(tint)
                Text(monogram)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let iconURL {
                    AsyncImage(url: iconURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                                .padding(size * 0.08)
                                .background(Color.white)
                        }
                    }
                    .clipShape(shape)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay { shape.stroke(Color.primary.opacity(0.08)) }
        .accessibilityHidden(true)
    }
}

/// "Searching Discourse Meta" style pill with the forum's icon.
struct AssistantForumPill: View {
    let forum: Forum?
    var prefix: String?
    var tint: Color = DCTheme.agentTint

    var body: some View {
        HStack(spacing: 6) {
            AssistantForumIcon(forum: forum, size: 18)
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var label: String {
        let name = forum?.displayName ?? String(localized: "No forum")
        guard let prefix else { return name }
        return String(
            localized: "forumPill.prefixAndName",
            defaultValue: "\(prefix) \(name)",
            comment: "Pill with a forum's icon: an action (e.g. “Searching”), then the forum name"
        )
    }
}

// MARK: - Mode switcher

// MARK: - Provider setup

/// Shown in place of the assistant's content while the mode's model can't
/// run (ModelSetup): what isn't ready, the one step that fixes it, and the
/// ready favorites to switch to instead. Never a dead end: without a ready
/// alternative, AI models… is still there.
struct ProviderSetupCard: View {
    @ObservedObject var app: AppModel
    let role: ModelRole

    private var selection: ModelSelection { app.selection(for: role) }
    private var readiness: ModelReadiness { app.readiness(for: role) }
    private var action: ModelSetupAction { ModelSetupAction(readiness, provider: selection.provider) }

    private var title: String {
        if role == .browserAgent {
            switch readiness {
            case .needsModel:
                return String(localized: "Choose a model for the agent", comment: "Browser agent setup card title when no model has been selected yet")
            case .needsKey:
                return String(localized: "\(selection.provider.displayName) needs an API key", comment: "Browser agent setup card title when the selected provider has no API key")
            default:
                break
            }
        }
        return String(
            localized: "\(app.providerSummary(for: role)) isn’t ready",
            comment: "Model not ready card title. The placeholder is a provider and model, e.g. Google Gemini · gemini-flash."
        )
    }

    private var detail: String {
        var lines: [String] = []
        if case .appleIntelligence(let reason) = readiness {
            lines.append(reason.title)
        } else {
            lines.append(String(localized: "Pick a model or add its key in Settings › AI models.", comment: "Model not ready card: how to fix it"))
        }
        // The other role still works on another model: say so.
        let other = app.selection(for: role.other)
        if other != selection, app.isReady(other) {
            lines.append(String(
                localized: "\(role.other.title) still works with \(other.provider.displayName).",
                comment: "Model not ready card: the other role's model is fine. Placeholders: the role (Summaries & chat, or Ask the forum) and a provider name."
            ))
        }
        return lines.joined(separator: " ")
    }

    var body: some View {
        let alternatives = app.readyAlternatives(for: role)
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: perform) {
                Text(action.title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DCActionButtonStyle(prominent: true))
            .accessibilityIdentifier("providerSetupButton")
            if !alternatives.isEmpty {
                Text("Or switch to one that’s ready", comment: "Model not ready card: heading above the ready favorite models")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(alternatives) { favorite in
                    Button {
                        app.activateFavorite(favorite, for: role)
                    } label: {
                        HStack(spacing: 8) {
                            Text(favorite.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(ModelReadiness.ready.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(DCTheme.success)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: DCTheme.controlHeight)
                        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DCTheme.controlCornerRadius, style: .continuous)
                                .stroke(DCTheme.border)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Switches to this model", comment: "Accessibility hint of a ready model in the model not ready card"))
                    .accessibilityIdentifier("readyModel-\(favorite.id)")
                }
            }
            if action != .aiModels {
                Button("AI models…") { app.requestedSettingsPage = .provider }
                    .font(.subheadline)
                    .frame(minHeight: DCTheme.controlHeight)
                    .accessibilityIdentifier("providerSetupSettings")
            }
        }
        .padding(16)
        .background(DCTheme.newRepliesBadgeBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.cardCornerRadius, style: .continuous)
                .stroke(DCTheme.warning.opacity(0.3))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providerSetupCard")
    }

    private func perform() {
        app.perform(action, for: role)
    }
}

// MARK: - Progress

/// Determinate bar that animates to its value, or a sliding indeterminate one.
///
/// Motion is computed from the clock (`TimelineView`), not started by
/// `onAppear`, so the bar moves whenever it is on screen — however and whenever
/// `value` changed (a job going from its fetch to the AI phase, a view
/// appearing mid-transition). While a job runs, a determinate bar carries a
/// sheen so a long step never looks frozen. With Reduce Motion the sweep and
/// sheen become a gentle pulse.
struct AssistantProgressBar: View {
    let value: Double?
    var tint: Color = DCTheme.summaryTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the indeterminate segment, as a fraction of the track.
    static let segment = 0.3
    /// Seconds for one sweep there and back.
    static let sweepPeriod: TimeInterval = 2.2
    static let sheenPeriod: TimeInterval = 2.2
    static let pulsePeriod: TimeInterval = 2.4

    /// Leading edge of the indeterminate segment (fraction of the track
    /// width) at `time`: glides back and forth between -0.1 and 0.8, so the
    /// segment is always mostly on the track (never an empty bar, no snap).
    static func sweepOffset(at time: TimeInterval, period: TimeInterval = sweepPeriod) -> Double {
        let wave = (1 - cos(time / period * 2 * .pi)) / 2
        return -0.1 + 0.9 * wave
    }

    /// 0…1 through the current sweep, eased at both ends.
    static func sweepPhase(at time: TimeInterval, period: TimeInterval) -> Double {
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        return (1 - cos(max(phase, 0) * .pi)) / 2
    }

    /// A slow breathing opacity between `low` and `high` (Reduce Motion).
    static func pulse(at time: TimeInterval, low: Double, high: Double) -> Double {
        let wave = (1 + sin(time / pulsePeriod * 2 * .pi)) / 2
        return low + (high - low) * wave
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                if let value {
                    determinate(value: value, width: width)
                        .transition(.opacity)
                } else {
                    indeterminate(width: width)
                        .transition(.opacity)
                }
            }
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.3), value: value == nil)
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func determinate(value: Double, width: CGFloat) -> some View {
        let fill = max(8, width * min(max(value, 0), 1))
        return Capsule()
            .fill(tint)
            .frame(width: fill)
            .animation(DCMotion.respecting(reduceMotion), value: value)
    }

    private func indeterminate(width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            if reduceMotion {
                Capsule()
                    .fill(tint)
                    .opacity(Self.pulse(at: time, low: 0.25, high: 0.65))
            } else {
                Capsule()
                    .fill(tint)
                    .frame(width: width * Self.segment)
                    .offset(x: width * Self.sweepOffset(at: time))
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Observes `ProgressStore` for one running job so parent screens (`AgentView`,
/// `HistoryView`) do not redraw on every progress tick.
struct WorkProgressBar: View {
    let recordID: UUID?
    @ObservedObject var progress: ProgressStore
    var tint: Color = DCTheme.summaryTint

    var body: some View {
        AssistantProgressBar(value: recordID.flatMap { progress.value(for: $0) }, tint: tint)
    }
}

/// Three pulsing dots while an answer is on its way.
struct TypingIndicator: View {
    var tint: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = reduceMotion ? 0.5 : (sin(time * 5 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * phase)
                        .scaleEffect(0.8 + 0.25 * phase)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Answering")
    }
}

// MARK: - Forum rows & loading state

/// A tappable forum row (icon, name, host).
struct AssistantForumRow: View {
    let forum: Forum
    var detail: String?
    var systemImage = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AssistantForumIcon(forum: forum, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(forum.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail ?? forum.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(minHeight: DCTheme.controlHeight)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(forum.displayName)")
    }
}

/// Subtle placeholder while the page has not been checked yet.
struct AssistantLoadingState: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                bar(width: 90, height: 10)
                bar(width: 230, height: 18)
                bar(width: nil, height: 12)
                bar(width: 180, height: 12)
                bar(width: nil, height: 46).padding(.top, 6)
            }
            .dcCard()
            VStack(alignment: .leading, spacing: 10) {
                bar(width: 120, height: 14)
                bar(width: nil, height: 12)
                bar(width: nil, height: 12)
                bar(width: 200, height: 12)
            }
            .dcCard()
            Label("Loading page…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading page")
        .accessibilityIdentifier("assistantLoadingState")
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2.4, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
    }
}
