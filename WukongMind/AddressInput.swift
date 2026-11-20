import Foundation

/// Classifies text entered in the address bar, Home's address field, or
/// onboarding into ordered actions; the first action is what Return runs.
///
/// Motion task 3: replaces the three separate resolvers (`HomeView.submitAddress`,
/// `PhoneBrowserBar.commitAddress`, `Onboarding.openSite`) with one pure
/// function while keeping their behaviour identical.
enum AddressInput {
    enum Action: Equatable {
        case open(URL)
        case forumSearch(URL)
        case webSearch(URL)

        var url: URL {
            switch self {
            case .open(let url), .forumSearch(let url), .webSearch(let url):
                return url
            }
        }
    }

    struct Context {
        var currentSiteURL: String?
        var forumSearchURL: ((String) -> URL?)?
        var webSearchURL: (String) -> URL?
    }

    static func actions(for rawText: String, context: Context) -> [Action] {
        PerfProbe.time("AddressInput.actions") {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }

            var result: [Action] = []
            if let url = ForumBrowserModel.resolveAddress(text, currentSiteURL: context.currentSiteURL) {
                result.append(.open(url))
            }
            if let forumURL = context.forumSearchURL?(text) {
                result.append(.forumSearch(forumURL))
            }
            if let webURL = context.webSearchURL(text) {
                result.append(.webSearch(webURL))
            }
            return result
        }
    }
}
