import SwiftUI

/// A saved Agent answer, read-only: the forum or site seal and the date, the
/// question as the title, the answer with its citation chips, then the numbered
/// sources. There is no composer and no follow-up. Layout follows
/// `docs/wukongmind/design/unified-canvas/PhoneSavedAnswer.dc.html`.
struct SavedAnswerView: View {
    let run: AgentRun
    /// The seal's text: the forum's name, or the site's host.
    let siteName: String
    let parse: AgentSources.Parse
    var backTitle: LocalizedStringKey = "History"
    let onBack: () -> Void
    /// A tapped source: the caller opens it in the browser.
    let onOpenSource: ([AgentSources.Source], AgentSources.Source) -> Void
    /// Any other link in the answer opens in the app's browser.
    var onOpenLink: (URL) -> Void = { _ in }

    private var sources: [AgentSources.Source] { run.sources.compactMap(\.source) }

    /// "Answer · 12 Nov"; there is no "read-only" in it.
    static func subtitle(for date: Date) -> String {
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return String(localized: "Answer · \(day)", comment: "Saved answer subtitle; the placeholder is the date, such as 12 Nov")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    DCHaptics.tap()
                    onBack()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                        Text(backTitle)
                            .font(.body)
                    }
                    .foregroundStyle(DCTheme.goldInk)
                    .frame(minHeight: 44)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("savedAnswerBack")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        DCSeal(text: siteName, variant: .outline)
                        Text(Self.subtitle(for: run.createdAt))
                            .font(.caption)
                            .foregroundStyle(DCTheme.inkMuted)
                    }
                    .accessibilityElement(children: .combine)

                    Text(verbatim: run.goal)
                        .font(.system(.title, weight: .bold))
                        .foregroundStyle(DCTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("savedAnswerQuestion")

                    MarkdownView(AgentSources.annotate(run.answer, sources: sources, parse: parse))
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("savedAnswerText")

                    if !sources.isEmpty {
                        DCSourcesList(sources: sources) { source in
                            onOpenSource(sources, source)
                        }
                        .padding(.top, 4)
                        .accessibilityIdentifier("savedAnswerSources")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard ForumBrowserModel.isBrowsableURL(url) else { return .systemAction }
                if let source = AgentSources.source(for: url, in: sources, parse: parse) {
                    onOpenSource(sources, source)
                    return .handled
                }
                onOpenLink(url)
                return .handled
            })
        }
        .background(DCTheme.pageBackground)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("savedAnswerView")
    }
}
