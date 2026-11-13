import SwiftUI

// MARK: - Suggestion row (One panel 2b)
//
// `design-system/components/SuggestionRow`: full questions above the composer.
// A tap sends the question; one ending in "…" fills the box instead. A
// suggestion that does not apply is absent (no disabled state). Selection and
// routing are pure (`PageSuggestions`) so unit tests need no engines.

/// What the panel's page is, for picking suggestions.
enum SuggestionPageKind: Equatable {
    case forumThread
    case forumList
    case ordinaryPage
}

/// One built-in suggestion. The raw value is its stable identifier.
enum PageSuggestion: String, CaseIterable, Identifiable {
    case summarizeThread
    case readAloud
    case searchForum
    case followReplies
    case worthReadingToday
    case summarizePage
    case makeDark
    case removeDistractions

    var id: String { rawValue }

    /// Exactly what gets sent (or, for `fillsComposer`, put in the box).
    var text: String {
        switch self {
        case .summarizeThread: String(localized: "Summarize this thread and replies", comment: "Suggestion above the Agent composer on a forum thread")
        case .readAloud: String(localized: "Read it to me", comment: "Suggestion above the Agent composer on a forum thread: reads the summary aloud")
        case .searchForum: String(localized: "Search this forum…", comment: "Suggestion above the Agent composer on a forum: fills the box to finish the search")
        case .followReplies: String(localized: "Notify me of new replies", comment: "Suggestion above the Agent composer on a forum thread: follows it")
        case .worthReadingToday: String(localized: "What's worth reading today", comment: "Suggestion above the Agent composer on a forum's topic list")
        case .summarizePage: String(localized: "Summarize this page", comment: "Suggestion above the Agent composer on an ordinary web page")
        case .makeDark: String(localized: "Make it dark", comment: "Suggestion above the Agent composer on an ordinary web page")
        case .removeDistractions: String(localized: "Remove distractions", comment: "Suggestion above the Agent composer on an ordinary web page")
        }
    }

    /// The box text a "…" suggestion leaves: its sentence start plus a space.
    var composerText: String {
        String(text.dropLast()).trimmingCharacters(in: .whitespaces) + " "
    }

    var fillsComposer: Bool { text.hasSuffix("…") }

    var systemImage: String? {
        switch self {
        case .summarizeThread: "text.alignleft"
        case .readAloud: "headphones"
        case .searchForum: "magnifyingglass"
        case .followReplies: "bell"
        default: nil
        }
    }
}

/// Where a suggestion runs during One panel (transitional, next-phase §7).
enum SuggestionRoute: Equatable {
    /// The existing summary engine.
    case summary
    /// The existing podcast read-aloud of the summary.
    case podcast
    /// Fill the box; once completed, the old Research loop.
    case fillForResearch
    /// The existing follow (watch) feature.
    case follow
    /// Send the text to the Agent.
    case agent
}

enum PageSuggestions {
    /// The page kind for the panel's state. Built-in forums (a recognized
    /// site) are `.topic` / `.forumHome`; everything else is an ordinary page.
    /// nil: no page open, or one still loading (its kind isn't known yet), so no row.
    static func pageKind(state: PageContext.State, hasPage: Bool) -> SuggestionPageKind? {
        switch state {
        case .topic: .forumThread
        case .forumHome: .forumList
        case .notForum, .maybe: hasPage ? .ordinaryPage : nil
        case .loading: nil
        }
    }

    /// The suggestions for a page, in order. "Summarize" is absent while a
    /// summary is being written, "Notify me" once the thread is followed.
    static func suggestions(
        for kind: SuggestionPageKind?,
        isFollowing: Bool = false,
        isSummarizing: Bool = false
    ) -> [PageSuggestion] {
        switch kind {
        case .forumThread:
            (isSummarizing ? [] : [.summarizeThread]) + [.readAloud, .searchForum] + (isFollowing ? [] : [.followReplies])
        case .forumList:
            [.worthReadingToday, .searchForum]
        case .ordinaryPage:
            [.summarizePage, .makeDark, .removeDistractions]
        case nil:
            []
        }
    }

    /// Thread suggestions run the old engines; the rest go to the Agent.
    static func route(for suggestion: PageSuggestion, on kind: SuggestionPageKind?) -> SuggestionRoute {
        switch (suggestion, kind) {
        case (.summarizeThread, .forumThread): .summary
        case (.readAloud, .forumThread): .podcast
        case (.followReplies, .forumThread): .follow
        case (.searchForum, .forumThread), (.searchForum, .forumList): .fillForResearch
        default: .agent
        }
    }

    /// The Research query when the box still starts with the filled-in
    /// "Search this forum" start; nil when it was removed or nothing follows.
    static func researchQuery(from draft: String) -> String? {
        let prefix = PageSuggestion.searchForum.composerText.trimmingCharacters(in: .whitespaces)
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : text
    }
}

/// The row of suggestion chips: outlined, `radius-md`, at most about four
/// visible, more scroll sideways. The tapped chip flies down into the box
/// (≤ 250 ms; a fade under Reduce Motion) before it runs.
struct SuggestionRowView: View {
    let suggestions: [PageSuggestion]
    let onTap: (PageSuggestion) -> Void
    @State private var flying: PageSuggestion?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let flightDuration = 0.22

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DCTheme.space2) {
                ForEach(suggestions) { suggestion in
                    chip(suggestion)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Suggestions", comment: "Accessibility label of the suggestion row above the Agent composer"))
        .accessibilityIdentifier("suggestionRow")
    }

    private func chip(_ suggestion: PageSuggestion) -> some View {
        let isFlying = flying == suggestion
        return Button {
            guard flying == nil else { return }
            DCHaptics.tap()
            withAnimation(.easeIn(duration: Self.flightDuration)) { flying = suggestion }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.flightDuration))
                onTap(suggestion)
                flying = nil
            }
        } label: {
            HStack(spacing: 6) {
                if let symbol = suggestion.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DCTheme.goldInk)
                        .accessibilityHidden(true)
                }
                Text(verbatim: suggestion.text)
                    .font(.subheadline)
                    .foregroundStyle(DCTheme.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, DCTheme.space3)
            .frame(minHeight: 36)
            .background(DCTheme.surface, in: RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DCTheme.radiusMd, style: .continuous)
                    .strokeBorder(DCTheme.borderStrong, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: isFlying && !reduceMotion ? 44 : 0)
        .opacity(isFlying ? 0 : 1)
        .accessibilityIdentifier("suggestion-\(suggestion.rawValue)")
    }
}
