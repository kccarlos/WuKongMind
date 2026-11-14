import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import WukongMind

/// M3 task 2 tests: `screenshot`, `network_log`, page-world `consoleLog`, and
/// before/after warning screenshots on a real `WKWebView` over loopback HTTP.
@MainActor
final class AgentPageCaptureTests: XCTestCase {
    private final class CaptureFixtureServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "AgentPageCaptureTests.Server")
        private(set) var port: UInt16 = 0

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
        }

        var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

        func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    guard !resumed, let self else { return }
                    if case .ready = state {
                        resumed = true
                        self.port = self.listener.port?.rawValue ?? 0
                        continuation.resume()
                    } else if case .failed(let error) = state {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }

        private func handle(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                    connection.cancel(); return
                }
                let parts = (req.split(separator: "\r\n").first ?? "").split(separator: " ")
                self.respond(to: parts.count > 1 ? String(parts[1]) : "/", on: connection)
            }
        }

        private func respond(to path: String, on connection: NWConnection) {
            var status = "200 OK"
            var contentType = "text/html; charset=utf-8"
            var extra = "Set-Cookie: sid=super-secret-cookie-999; Path=/\r\n"
            let body: String
            switch path {
            case "/capture":
                body = """
                <!doctype html><html><head><meta charset="utf-8"><title>Capture Fixture</title></head><body>
                <script>
                console.log('page boot', { ok: true });
                console.warn('long-' + 'x'.repeat(620));
                (async () => {
                  await fetch('/api/items?tag=alpha', {
                    method: 'POST',
                    headers: { 'Authorization': 'Bearer secret-fetch-token-123', 'Content-Type': 'application/json' },
                    body: '{"q":"hello"}'
                  });
                  await new Promise((resolve, reject) => {
                    const xhr = new XMLHttpRequest();
                    xhr.open('GET', '/api/xhr-notes');
                    xhr.setRequestHeader('Authorization', 'Bearer secret-xhr-token-456');
                    xhr.onload = () => resolve(xhr.status);
                    xhr.onerror = () => reject(new Error('xhr failed'));
                    xhr.send();
                  });
                  document.body.setAttribute('data-ready', '1');
                })();
                </script></body></html>
                """
            case "/api/items?tag=alpha":
                contentType = "application/json"
                extra += "Set-Cookie: resp_cookie=never-leak-789; Path=/\r\n"
                body = #"{"ok":true,"pad":"\#(String(repeating: "A", count: 2_400))"}"#
            case "/api/xhr-notes":
                contentType = "text/plain; charset=utf-8"
                extra += "Set-Cookie: xhr_cookie=never-leak-000; Path=/\r\n"
                body = "xhr body note"
            case "/slow-stream":
                let chunk = Data("delayed body payload".utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(chunk.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), isComplete: false, completion: .contentProcessed { [weak self] _ in
                    self?.queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                        connection.send(content: chunk, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                })
                return
            case "/tall":
                let bands = (1...10).map { i in
                    #"<div style="height:300px;background:hsl(\#(i * 33),70%,35%);color:#fff;font:bold 28px sans-serif">Band \#(i)</div>"#
                }.joined()
                body = "<!doctype html><html><body style='margin:0'>\(bands)</body></html>"
            case "/tall-phone":
                let bands = (1...10).map { i in
                    #"<div style="height:900px;background:hsl(\#(i * 33),70%,35%);color:#fff;font:bold 28px sans-serif">Phone Band \#(i)</div>"#
                }.joined()
                body = "<!doctype html><html><body style='margin:0'>\(bands)</body></html>"
            case "/article":
                let prose = String(repeating: "Readable forum article paragraph with plenty of words for page feedback. ", count: 20)
                body = """
                <!doctype html><html><body style="margin:0;padding:24px;background:#1e3a8a;color:#fef08a;font:20px sans-serif">
                <h1>Forum Thread Title</h1><p>\(prose)</p>
                <nav><a href="/a">1</a> <a href="/b">2</a> <a href="/c">3</a> <a href="/d">4</a></nav></body></html>
                """
            default:
                status = "404 Not Found"; body = "Not found"
            }
            let bodyData = Data(body.utf8)
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\n"
                + "\(extra)Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + bodyData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private var server: CaptureFixtureServer!
    private var browser: ForumBrowserModel!
    private var window: UIWindow?
    private var sandbox: URL!

    override func setUp() async throws {
        try await super.setUp()
        server = try CaptureFixtureServer()
        try await server.start()
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("AgentPageCapture-\(UUID().uuidString)", isDirectory: true)
        browser = ForumBrowserModel(contentRules: ContentRuleLibrary(store: nil, directory: nil), websiteDataStore: .nonPersistent())
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let win = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        root.view.frame = win.bounds
        root.view.addSubview(browser.webView)
        browser.webView.frame = root.view.bounds
        win.rootViewController = root
        win.makeKeyAndVisible()
        window = win
    }

    override func tearDown() async throws {
        browser?.stopLoading()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        browser = nil
        server?.stop()
        server = nil
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        try await super.tearDown()
    }

    private func makeRegistry(supportsImageInput: Bool) -> ToolRegistry {
        ToolRegistry.m3(context: AgentToolContext(
            bridge: browser.agentBridge,
            workspace: AgentWorkspace(root: sandbox.appendingPathComponent("Documents", isDirectory: true)),
            scriptStore: ScriptStore(directoryURL: sandbox.appendingPathComponent("Scripts", isDirectory: true)),
            settings: AgentToolSettings(supportsImageInput: supportsImageInput)
        ))
    }

    func testScreenshotToolIsHiddenWhenSupportsImageInputIsFalse() {
        let vision = makeRegistry(supportsImageInput: true).definitions.map(\.name)
        let textOnly = makeRegistry(supportsImageInput: false).definitions.map(\.name)
        XCTAssertTrue(vision.contains("screenshot") && vision.contains("network_log"))
        XCTAssertFalse(textOnly.contains("screenshot"))
        XCTAssertTrue(textOnly.contains("network_log"))
    }

    func testNetworkLogAndConsoleCaptureFetchAndXHRWithoutCookieOrAuthHeaders() async throws {
        let registry = makeRegistry(supportsImageInput: true)
        _ = try await browser.agentBridge.load(server.baseURL.appendingPathComponent("capture"), wait: true, timeout: 10)
        _ = try await browser.agentBridge.waitFor(selector: "body[data-ready='1']", milliseconds: 5_000)

        let all = try await registry.dispatch(toolName: "network_log", arguments: [:])
        XCTAssertEqual(all.resultSummary, "2")
        let lines = all.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let newest = try JSONValue.parseObjectJSON(lines[0])
        let older = try JSONValue.parseObjectJSON(lines[1])
        XCTAssertEqual(newest["kind"], .string("xhr"))
        XCTAssertEqual(newest["status"], .int(200))
        XCTAssertNil(newest["response_preview"])
        XCTAssertEqual(older["kind"], .string("fetch"))
        XCTAssertEqual(older["method"], .string("POST"))
        XCTAssertNil(older["response_preview"])

        let filtered = try await registry.dispatch(toolName: "network_log", arguments: ["url_filter": .string("TAG=ALPHA")])
        XCTAssertEqual(filtered.resultSummary, "1")
        XCTAssertTrue(filtered.output.contains("/api/items?tag=alpha"))

        let limited = try await registry.dispatch(toolName: "network_log", arguments: ["limit": .int(1)])
        XCTAssertEqual(limited.output.split(separator: "\n").count, 1)
        XCTAssertTrue(limited.output.contains("/api/xhr-notes"))

        let withBodies = try await registry.dispatch(toolName: "network_log", arguments: ["include_bodies": .bool(true)])
        let bodyLines = withBodies.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(try JSONValue.parseObjectJSON(bodyLines[0])["response_preview"], .string("xhr body note"))
        XCTAssertEqual(try JSONValue.parseObjectJSON(bodyLines[1])["response_preview"]?.stringValue?.count, 2_000)

        for forbidden in ["Authorization", "secret-fetch-token", "secret-xhr-token", "Cookie", "Set-Cookie", "super-secret-cookie", "never-leak"] {
            XCTAssertFalse(withBodies.output.contains(forbidden), "Leaked '\(forbidden)'")
        }

        let consoleEntries = try await browser.agentBridge.consoleLog()
        XCTAssertEqual(consoleEntries.count, 2)
        XCTAssertEqual(consoleEntries[0].level, "warn")
        XCTAssertEqual(consoleEntries[0].text.count, 500)
        XCTAssertTrue(consoleEntries[1].text.contains("page boot"))

        // Fetch must resolve as soon as headers arrive instead of blocking up to 150 ms for body preview.
        let timing = try await browser.agentBridge.runJS(
            code: "const t0 = performance.now(); const r = await fetch('/slow-stream'); return Math.round(performance.now() - t0) + ':' + r.status;",
            environment: .page,
            timeout: 5
        )
        let parts = (timing.valueJSON ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: ":")
        let headerMs = Int(parts.first ?? "999") ?? 999
        XCTAssertEqual(parts.last, "200")
        XCTAssertLessThan(headerMs, 120, "fetch() must not wait for body preview before resolving")
    }

    func testScreenshotScalesToAtMost1280PxAndCapsFullPageAtEightScreens() async throws {
        let registry = makeRegistry(supportsImageInput: true)

        // At 390x844 pt (@3x on iPhone), 8 screens is 6,752 pt (20,256 native px); pixel height must stay <= 8,000.
        let phoneRect = CGRect(x: 0, y: 0, width: 390, height: 844)
        window?.frame = phoneRect
        window?.rootViewController?.view.frame = phoneRect
        browser.webView.frame = phoneRect
        browser.webView.layoutIfNeeded()
        _ = try await browser.agentBridge.load(server.baseURL.appendingPathComponent("tall-phone"), wait: true, timeout: 10)
        try await Task.sleep(for: .milliseconds(100))

        let phoneFull = try await registry.dispatch(toolName: "screenshot", arguments: ["area": .string("full_page")])
        XCTAssertEqual(phoneFull.resultSummary, "390×6752 pt")
        XCTAssertTrue(phoneFull.output.contains("390×6752 pt, full page") && phoneFull.output.contains("capped at 8 screen heights"), phoneFull.output)
        let phoneData = try XCTUnwrap(Data(base64Encoded: phoneFull.images[0].data))
        let phoneCG = try XCTUnwrap(UIImage(data: phoneData)?.cgImage)
        XCTAssertLessThanOrEqual(phoneCG.width, 1_280)
        XCTAssertLessThanOrEqual(phoneCG.height, 8_000)
        XCTAssertEqual(Double(phoneCG.height) / Double(phoneCG.width), 6752.0 / 390.0, accuracy: 0.08)

        let wideRect = CGRect(x: 0, y: 0, width: 700, height: 300)
        window?.frame = wideRect
        window?.rootViewController?.view.frame = wideRect
        browser.webView.frame = wideRect
        browser.webView.layoutIfNeeded()

        _ = try await browser.agentBridge.load(server.baseURL.appendingPathComponent("tall"), wait: true, timeout: 10)
        try await Task.sleep(for: .milliseconds(100))

        let visible = try await registry.dispatch(toolName: "screenshot", arguments: [:])
        XCTAssertEqual(visible.resultSummary, "700×300 pt")
        XCTAssertTrue(visible.output.contains("700×300 pt, visible"), visible.output)
        let visibleData = try XCTUnwrap(Data(base64Encoded: visible.images[0].data))
        XCTAssertEqual([UInt8](visibleData.prefix(2)), [0xFF, 0xD8])
        let visibleCG = try XCTUnwrap(UIImage(data: visibleData)?.cgImage)
        XCTAssertLessThanOrEqual(visibleCG.width, 1_280)
        XCTAssertLessThanOrEqual(visibleCG.height, 8_000)

        let fullPage = try await registry.dispatch(toolName: "screenshot", arguments: ["area": .string("full_page")])
        XCTAssertEqual(fullPage.resultSummary, "700×2400 pt")
        XCTAssertTrue(fullPage.output.contains("700×2400 pt, full page") && fullPage.output.contains("capped at 8 screen heights"), fullPage.output)
        let fullData = try XCTUnwrap(Data(base64Encoded: fullPage.images[0].data))
        let fullCG = try XCTUnwrap(UIImage(data: fullData)?.cgImage)
        XCTAssertLessThanOrEqual(fullCG.width, 1_280)
        XCTAssertLessThanOrEqual(fullCG.height, 8_000)
        XCTAssertEqual(Double(fullCG.height) / Double(fullCG.width), 2400.0 / 700.0, accuracy: 0.05)
    }

    func testWarningCarriesBeforeAndAfterImagesOnlyWhenModelSupportsImages() async throws {
        _ = try await browser.agentBridge.load(server.baseURL.appendingPathComponent("article"), wait: true, timeout: 10)
        try await Task.sleep(for: .milliseconds(100))

        let visionRegistry = makeRegistry(supportsImageInput: true)
        let benign = try await visionRegistry.dispatch(toolName: "run_js", arguments: ["code": .string("document.title = 'Retitled'; return 'ok';")])
        XCTAssertEqual(benign.pageFeedback?.isWarning, false)
        XCTAssertTrue(benign.images.isEmpty)

        let broken = try await visionRegistry.dispatch(
            toolName: "run_js",
            arguments: ["code": .string("document.body.innerHTML = ''; document.body.style.background = '#ffffff'; return 'wiped';")]
        )
        XCTAssertEqual(broken.pageFeedback?.isWarning, true)
        XCTAssertEqual(broken.images.count, 2)
        XCTAssertNotEqual(broken.images[0].data, broken.images[1].data)

        _ = try await browser.agentBridge.load(server.baseURL.appendingPathComponent("article"), wait: true, timeout: 10)
        try await Task.sleep(for: .milliseconds(100))
        let brokenTextOnly = try await makeRegistry(supportsImageInput: false).dispatch(
            toolName: "run_js",
            arguments: ["code": .string("document.body.innerHTML = ''; return 'wiped';")]
        )
        XCTAssertEqual(brokenTextOnly.pageFeedback?.isWarning, true)
        XCTAssertTrue(brokenTextOnly.images.isEmpty)
    }
}
