import Foundation
import WebKit
import XCTest
@testable import WukongMind

/// The fixed "looks like a thread" check (Learn on ask 8) on saved pages: four
/// engines it must flag and four ordinary pages it must not. It runs in a
/// `WKWebView` on `loadHTMLString`, so it can only read the page it was given.
@MainActor
final class LookLikeThreadProbeTests: XCTestCase {
    private final class Delegate: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        var requests: [URL] = []
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = action.request.url { requests.append(url) }
            return .allow
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(); continuation = nil }
    }

    private func fixture(_ name: String) throws -> String {
        if let url = Bundle(for: Self.self).url(forResource: name, withExtension: "html") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LookLikeThread/\(name).html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func probe(_ name: String) async throws -> (facts: PageFacts, requests: [URL]) {
        let delegate = Delegate()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.navigationDelegate = delegate
        let base = URL(string: "https://bbs.example.net/thread-1-1.html")!
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.continuation = cont
            webView.loadHTMLString(try! fixture(name), baseURL: base)
        }
        let value = try await webView.callAsyncJavaScript(
            "return (\(PageFactsProbe.expression(keys: .common)))();", arguments: [:], in: nil, contentWorld: .defaultClient
        )
        let dictionary = try XCTUnwrap(value as? [String: Any])
        return (PageFacts(probe: dictionary, fallbackURL: base), delegate.requests)
    }

    func testTrueOnForumPages() async throws {
        for name in ["forum-fluxbb", "forum-xenforo", "forum-discourse", "forum-nodebb"] {
            let result = try await probe(name)
            XCTAssertTrue(result.facts.looksLikeThread, name)
        }
    }

    func testFalseOnOrdinaryPages() async throws {
        for name in ["plain-wikipedia", "plain-bbc-news", "plain-python-docs", "plain-github-repo"] {
            let result = try await probe(name)
            XCTAssertFalse(result.facts.looksLikeThread, name)
        }
    }

    func testTrueOnEachMarkupPath() async throws {
        for name in ["markup-jsonld", "markup-generator", "markup-microdata"] {
            let result = try await probe(name)
            XCTAssertTrue(result.facts.looksLikeThread, name)
        }
    }

    func testTheCheckMakesNoRequest() async throws {
        for name in ["forum-fluxbb", "plain-wikipedia"] {
            let result = try await probe(name)
            // Only the document's own load: the check adds none.
            XCTAssertEqual(result.requests.count, 1, name)
        }
        let source = PageFactsProbe.looksLikeThreadFunction
        for word in ["fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "import("] {
            XCTAssertFalse(source.contains(word), word)
        }
    }

    func testMissingKeyReadsAsFalse() {
        XCTAssertFalse(PageFacts(probe: [:], fallbackURL: URL(string: "https://example.org/")!).looksLikeThread)
    }
}
