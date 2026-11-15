import Foundation
@testable import WukongMind

/// Static `AgentPageDriving` double for the One loop comparison harness: serves
/// `read_page` from `SavedPage` and refuses every page-changing or live-DOM tool.
struct FixturePageDriver: AgentPageDriving {
    struct SavedPage: Codable, Equatable, Sendable {
        var url: String
        var title: String
        var structure: String = ""
        var text: String = ""
        var html: String = ""
    }

    enum PageError: LocalizedError, Equatable, Sendable {
        case pageMutationDisabled(String)
        case selectorUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .pageMutationDisabled(let op):
                "Fixture page driver refuses '\(op)': page changes are disabled in forum comparison runs."
            case .selectorUnsupported(let selector):
                "Fixture page driver cannot query CSS selector '\(selector)' without a live DOM."
            }
        }
    }

    static let defaultStructureMaxChars = 12_000
    /// The page shown now; `show(_:)` swaps it (a page change between turns, WUKO-73).
    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SavedPage
        init(_ value: SavedPage) { self.value = value }
        var page: SavedPage {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
    private let holder: Holder
    var page: SavedPage { holder.page }

    init(page: SavedPage) { holder = Holder(page) }

    func show(_ page: SavedPage) { holder.page = page }

    func currentPageMetadata() async -> AgentPageMetadata {
        AgentPageMetadata(url: page.url, title: page.title)
    }

    func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String {
        if let trimmed = selector?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            throw PageError.selectorUnsupported(trimmed)
        }
        let raw = switch mode {
        case .structure: page.structure
        case .text: page.text
        case .html: page.html
        }
        let cap = maxLength ?? (mode == .structure ? Self.defaultStructureMaxChars : nil)
        guard let cap, cap > 0, raw.count > cap else { return raw }
        return "\(raw.prefix(cap))\n...[truncated, \(raw.count) characters in total]"
    }

    func runJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
        throw PageError.pageMutationDisabled("run_js")
    }
    func runAgentJS(code: String, environment: AgentExecutionEnvironment, timeout: TimeInterval) async throws -> JSExecutionResult {
        throw PageError.pageMutationDisabled("run_js")
    }
    func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult {
        throw PageError.pageMutationDisabled("inject_css")
    }
    func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult {
        throw PageError.pageMutationDisabled("wait_for")
    }
    func load(_ url: URL, wait: Bool, timeout: TimeInterval) async throws -> AgentNavigationOutcome {
        throw PageError.pageMutationDisabled("navigate")
    }
    func reload(timeout: TimeInterval) async throws -> AgentNavigationOutcome {
        throw PageError.pageMutationDisabled("reload_page")
    }
    func screenshot(area: ScreenshotArea) async throws -> AgentScreenshot {
        throw PageError.pageMutationDisabled("screenshot")
    }
}
