import SwiftUI

// The one conversation's building blocks from the WukongMind design system:
// ToolRow, ResultCard, Message notes and the rise-into-view motion.
// Components: docs/wukongmind/design/design-system/components/.

// MARK: - Motion

/// A result rises 8 pt into view in 220 ms (at most 250); with Reduce Motion it only fades.
private struct DCRiseIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.22)) { shown = true }
            }
    }
}

extension View {
    /// How a new result enters the conversation.
    func dcRiseIn() -> some View { modifier(DCRiseIn()) }
}

// MARK: - ToolRow

/// Plain labels for the browser Agent's tools: present progressive while running,
/// past tense when done. Code names show only in developer mode.
enum DCToolLabel {
    static func browser(_ tool: String, running: Bool) -> String {
        switch tool {
        case "read_page": running ? String(localized: "Reading page") : String(localized: "Read page")
        case "run_js": running ? String(localized: "Running script") : String(localized: "Ran script")
        case "inject_css": running ? String(localized: "Styling page") : String(localized: "Styled page")
        case "wait_for": running ? String(localized: "Waiting for page") : String(localized: "Waited for page")
        case "script_save": running ? String(localized: "Saving script") : String(localized: "Saved script")
        case "script_list": running ? String(localized: "Listing scripts") : String(localized: "Listed scripts")
        case "script_read": running ? String(localized: "Reading script") : String(localized: "Read script")
        case "script_update": running ? String(localized: "Updating script") : String(localized: "Updated script")
        case "script_delete": running ? String(localized: "Deleting script") : String(localized: "Deleted script")
        case "screenshot": running ? String(localized: "Taking screenshot") : String(localized: "Took screenshot")
        case "network_log": running ? String(localized: "Reading network log") : String(localized: "Read network log")
        case "navigate": running ? String(localized: "Opening page") : String(localized: "Opened page")
        case "reload_page": running ? String(localized: "Reloading page") : String(localized: "Reloaded page")
        case "http_request": running ? String(localized: "Sending request") : String(localized: "Sent request")
        case "cookies_get": running ? String(localized: "Reading cookies") : String(localized: "Read cookies")
        case "file_read": running ? String(localized: "Reading file") : String(localized: "Read file")
        case "file_write": running ? String(localized: "Writing file") : String(localized: "Wrote file")
        case "file_list": running ? String(localized: "Listing files") : String(localized: "Listed files")
        case "search_forum": running ? String(localized: "Searching forum") : String(localized: "Searched forum")
        case "search_comments": running ? String(localized: "Searching comments") : String(localized: "Searched comments")
        case "list_latest": running ? String(localized: "Listing latest") : String(localized: "Listed latest")
        case "read_topic": running ? String(localized: "Reading thread") : String(localized: "Read thread")
        default: running ? String(localized: "Using a tool") : String(localized: "Used a tool")
        }
    }
}

/// One step as a single line: a 28 pt disc (check, turning gold ring or cinnabar triangle),
/// a plain label, an optional summary; tap expands `detail`.
struct DCToolRow<Detail: View>: View {
    enum State { case running, done, warning, error }

    let label: String
    var codeName: String?
    var duration: String?
    var summary: String = ""
    let state: State
    var isExpanded = false
    var onToggle: (() -> Void)?
    @ViewBuilder var detail: () -> Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onToggle?() } label: {
                HStack(spacing: 10) {
                    disc
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: codeName ?? label)
                            .font(codeName == nil
                                ? .subheadline.weight(.semibold)
                                : .subheadline.weight(.semibold).monospaced())
                            .foregroundStyle(state == .running ? DCTheme.goldInk : DCTheme.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        if !summary.isEmpty {
                            Text(verbatim: summary)
                                .font(.caption)
                                .foregroundStyle(state == .error ? DCTheme.danger : (state == .warning ? DCTheme.warning : DCTheme.inkMuted))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 4)
                    if let duration {
                        Text(verbatim: duration)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DCTheme.inkMuted)
                    }
                    if onToggle != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DCTheme.inkFaint)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [label, codeName, summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
            .accessibilityIdentifier("agentToolRow")

            if isExpanded {
                detail().padding(.leading, 38).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var disc: some View {
        switch state {
        case .running:
            DCAgentRing(size: 28, lineWidth: DCTheme.ringWidth, isTurning: true)
        case .done:
            Circle().fill(DCTheme.surfaceRaised).frame(width: 28, height: 28)
                .overlay { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(DCTheme.inkMuted) }
        case .warning:
            Circle().fill(DCTheme.surfaceRaised).frame(width: 28, height: 28)
                .overlay { Image(systemName: "exclamationmark.triangle").font(.caption.weight(.bold)).foregroundStyle(DCTheme.warning) }
        case .error:
            Circle().fill(DCTheme.cinnabarWash).frame(width: 28, height: 28)
                .overlay { Image(systemName: "exclamationmark.triangle.fill").font(.caption.weight(.bold)).foregroundStyle(DCTheme.danger) }
        }
    }
}

extension DCToolRow where Detail == EmptyView {
    init(label: String, codeName: String? = nil, duration: String? = nil, summary: String = "", state: State) {
        self.init(label: label, codeName: codeName, duration: duration, summary: summary, state: state, detail: { EmptyView() })
    }
}

/// The folded run: "Steps N" with a chevron; `content` shows when expanded.
struct DCStepsFold<Content: View>: View {
    let count: Int
    let errorCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Text("Steps \(count)", comment: "Folded Agent steps header showing the number of tool calls")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DCTheme.ink)
                    if errorCount > 0 {
                        Text("\(errorCount) errors", comment: "Agent steps header: tool error count")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DCTheme.danger)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DCTheme.inkFaint)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("agentStepsSummary")
            if isExpanded { content() }
        }
    }
}

// MARK: - ResultCard

/// A tool result the user reads: `surface`, hairline edge, `radius-lg`, with a jade header strip
/// (jade means "this came from the website").
struct DCResultCard<Trailing: View, Content: View>: View {
    let label: String
    var systemImage = "doc.text"
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.caption.weight(.semibold)).accessibilityHidden(true)
                Text(verbatim: label).font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                trailing().foregroundStyle(DCTheme.jade)
            }
            .foregroundStyle(DCTheme.jade)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DCTheme.jadeWash)

            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DCTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous)
                .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
        }
        .dcRiseIn()
    }
}

/// The jade header strip of a ResultCard on its own, for results whose rows must stay lazy.
struct DCResultHeader: View {
    let label: String
    var systemImage = "doc.text"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption.weight(.semibold)).accessibilityHidden(true)
            Text(verbatim: label).font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DCTheme.jade)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DCTheme.jadeWash, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
        .dcRiseIn()
    }
}

/// A numbered citation: jade-wash square, jade number, at least 20 pt.
struct DCCitationChip: View {
    let number: String

    var body: some View {
        Text(verbatim: number)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(DCTheme.jade)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 2)
            .background(DCTheme.jadeWash, in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The listen row: a round ink play button, the title, a gold progress bar and the time left.
struct DCListenRow: View {
    let title: String
    let detail: String
    let progress: Double
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(DCTheme.ink).frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline).foregroundStyle(DCTheme.ground)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(DCTheme.ink).lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(DCTheme.surfaceRaised)
                        .overlay(alignment: .leading) {
                            Capsule().fill(DCTheme.gold).frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                }
                .frame(height: 4)
                Text(verbatim: detail).font(.caption.monospacedDigit()).foregroundStyle(DCTheme.inkMuted).lineLimit(1)
            }
        }
        .padding(12)
        .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DCTheme.radiusLg, style: .continuous)
                .strokeBorder(DCTheme.hairline, lineWidth: DCTheme.hairlineWidth)
        }
        .dcRiseIn()
    }
}

// MARK: - Message

/// The user's bubble: three `radius-lg` corners, `radius-sm` bottom-trailing.
struct DCUserBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: DCTheme.radiusLg,
                bottomLeading: DCTheme.radiusLg,
                bottomTrailing: DCTheme.radiusSm,
                topTrailing: DCTheme.radiusLg
            ),
            style: .continuous
        )
    }
}

/// "Saved. Faster next time.": a gold-wash chip with the ring glyph.
struct DCSavedNote: View {
    var body: some View {
        HStack(spacing: 6) {
            DCAgentRing(size: 14, lineWidth: 1.5)
            Text("Saved. Faster next time.", comment: "Note after the Agent saves a script")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(DCTheme.goldInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DCTheme.goldWash, in: RoundedRectangle(cornerRadius: DCTheme.radiusSm, style: .continuous))
        .accessibilityIdentifier("agentSavedNote")
    }
}
