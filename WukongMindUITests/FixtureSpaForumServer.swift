import Foundation
import Network
import XCTest

/// A local non-Discourse single-page forum fixture served on `127.0.0.1` for M2
/// end-to-end userscript persistence, reload, app-relaunch, SPA `pushState`,
/// and Script Manager toggle-off verification.
final class FixtureSpaForumServer: @unchecked Sendable {
    static let thread101OP = "OP: Calm tools respect your attention and stay out of the way."
    static let thread101Reply1 = "Reply by Liam: Completely agree, fewer popups means deeper focus."
    static let thread101Reply2 = "Reply by Noah: How do you handle urgent alerts without noise?"

    static let thread102OP = "OP: Offline reading on the subway works great with cached pages."
    static let thread102Reply1 = "Reply by Ava: Cached threads make commutes way better."
    static let thread102Reply2 = "Reply by Sam: Syncing read state when back online is key."

    private let queue = DispatchQueue(label: "fixture-spa-forum")
    private let lock = NSLock()
    private var listener: NWListener?
    private var pathCounts: [String: Int] = [:]
    private var htmlLoads = 0
    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var thread101URL: String { "\(baseURL)/threads/101" }
    var thread102URL: String { "\(baseURL)/threads/102" }

    var totalHTMLLoads: Int {
        lock.withLock { htmlLoads }
    }

    func requestCount(forPath path: String) -> Int {
        lock.withLock { pathCounts[path, default: 0] }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let path = Self.parseRequestPath(buffer) {
                let payload = self.response(forPath: path)
                connection.send(
                    content: payload,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private static func parseRequestPath(_ data: Data) -> String? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8),
              let firstLine = head.components(separatedBy: "\r\n").first
        else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        return URLComponents(string: target)?.path ?? target
    }

    private func response(forPath path: String) -> Data {
        if path == "/favicon.ico" {
            let headers = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return Data(headers.utf8)
        }

        if path.hasPrefix("/crawl/page-"), let page = Self.crawlPage(path) {
            lock.withLock { pathCounts[path, default: 0] += 1 }
            let head = [
                "HTTP/1.1 200 OK", "Content-Type: text/html; charset=utf-8", "Cache-Control: no-store",
                "Content-Length: \(page.count)", "Connection: close", "", ""
            ].joined(separator: "\r\n")
            return Data(head.utf8) + page
        }

        let initialThreadID = path.hasSuffix("/102") ? 102 : 101
        let loadNumber: Int = lock.withLock {
            pathCounts[path, default: 0] += 1
            htmlLoads += 1
            return htmlLoads
        }

        let body = Data(Self.pageHTML(initialThreadID: initialThreadID, loadNumber: loadNumber).utf8)
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Cache-Control: no-store",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }

    /// The 25-page crawl fixture (M3 acceptance check 1), read from the checked-in files.
    private static func crawlPage(_ path: String) -> Data? {
        let name = String(path.dropFirst("/crawl/".count))
        guard name.range(of: #"^page-(0[1-9]|1[0-9]|2[0-5])\.html$"#, options: .regularExpression) != nil else { return nil }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WukongMindTests/Fixtures/CrawlForum/\(name)")
        return try? Data(contentsOf: url)
    }

    private static func pageHTML(initialThreadID: Int, loadNumber: Int) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>IndieBoard · Thread #\(initialThreadID)</title>
          <style>
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              background: #f8fafc;
              color: #0f172a;
              line-height: 1.5;
            }
            header.site-bar {
              display: flex;
              align-items: center;
              justify-content: space-between;
              padding: 12px 16px;
              background: #ffffff;
              border-bottom: 1px solid #e2e8f0;
            }
            .brand { font-weight: 700; font-size: 0.95rem; }
            .stamps { display: flex; gap: 8px; font-size: 0.78rem; color: #475569; }
            .stamp-pill {
              padding: 2px 8px;
              border-radius: 999px;
              background: #f1f5f9;
              border: 1px solid #cbd5e1;
            }
            main.board {
              max-width: 680px;
              margin: 0 auto;
              padding: 16px;
            }
            h1#thread-title {
              margin: 0 0 10px;
              font-size: 1.25rem;
            }
            nav.thread-switcher {
              margin-bottom: 14px;
            }
            a.spa-link {
              display: inline-block;
              padding: 7px 12px;
              border-radius: 8px;
              background: #eff6ff;
              border: 1px solid #bfdbfe;
              color: #1d4ed8;
              font-size: 0.88rem;
              font-weight: 600;
              text-decoration: none;
            }
            .posts-list {
              display: flex;
              flex-direction: column;
              gap: 10px;
            }
            article.forum-post {
              background: #ffffff;
              border: 1px solid #e2e8f0;
              border-radius: 10px;
              padding: 12px 14px;
            }
            article.forum-post.op-post {
              border-left: 4px solid #2563eb;
            }
            .post-header {
              display: flex;
              align-items: center;
              gap: 8px;
              margin-bottom: 6px;
              font-size: 0.84rem;
            }
            .author-name { font-weight: 600; }
            .role-badge {
              padding: 1px 7px;
              border-radius: 999px;
              font-size: 0.74rem;
              font-weight: 600;
            }
            .op-badge {
              background: #dbeafe;
              color: #1e40af;
            }
            .reply-badge {
              background: #f1f5f9;
              color: #475569;
            }
            .post-number {
              margin-left: auto;
              color: #64748b;
            }
            p.post-body {
              margin: 0;
              font-size: 0.94rem;
            }
          </style>
        </head>
        <body>
          <header class="site-bar">
            <span class="brand">IndieBoard</span>
            <div class="stamps">
              <span id="http-load-stamp" class="stamp-pill">Load #\(loadNumber)</span>
              <span id="spa-route-stamp" class="stamp-pill">Thread #\(initialThreadID) · SPA route #1</span>
            </div>
          </header>
          <main class="board">
            <h1 id="thread-title"></h1>
            <nav class="thread-switcher">
              <a id="spa-next-thread" class="spa-link" href="/threads/102">Next thread: Offline Reading</a>
            </nav>
            <section id="thread-posts" class="posts-list"></section>
          </main>
          <script>
            const THREADS = {
              101: {
                title: "Why calm tools last longer",
                nextId: 102,
                nextLabel: "Next thread: Offline Reading",
                posts: [
                  {
                    role: "op",
                    author: "Maya Chen",
                    badge: "Original Poster",
                    number: "#1",
                    body: \(jsString(thread101OP))
                  },
                  {
                    role: "reply",
                    author: "Liam Patel",
                    badge: "Reply",
                    number: "#2",
                    body: \(jsString(thread101Reply1))
                  },
                  {
                    role: "reply",
                    author: "Noah Kim",
                    badge: "Reply",
                    number: "#3",
                    body: \(jsString(thread101Reply2))
                  }
                ]
              },
              102: {
                title: "Offline reading on the subway",
                nextId: 101,
                nextLabel: "Previous thread: Calm Tools",
                posts: [
                  {
                    role: "op",
                    author: "Elena Rostova",
                    badge: "Original Poster",
                    number: "#1",
                    body: \(jsString(thread102OP))
                  },
                  {
                    role: "reply",
                    author: "Ava Brooks",
                    badge: "Reply",
                    number: "#2",
                    body: \(jsString(thread102Reply1))
                  },
                  {
                    role: "reply",
                    author: "Sam Rivera",
                    badge: "Reply",
                    number: "#3",
                    body: \(jsString(thread102Reply2))
                  }
                ]
              }
            };

            let spaRouteCount = 1;

            function renderThread(threadId) {
              const thread = THREADS[threadId] || THREADS[101];
              document.title = "IndieBoard · Thread #" + threadId;
              document.getElementById("thread-title").textContent = thread.title;
              document.getElementById("spa-route-stamp").textContent =
                "Thread #" + threadId + " · SPA route #" + spaRouteCount;

              const nextLink = document.getElementById("spa-next-thread");
              nextLink.href = "/threads/" + thread.nextId;
              nextLink.textContent = thread.nextLabel;
              nextLink.dataset.targetThread = String(thread.nextId);

              const container = document.getElementById("thread-posts");
              container.replaceChildren();
              for (const post of thread.posts) {
                const isOp = post.role === "op";
                const article = document.createElement("article");
                article.className = "forum-post " + (isOp ? "op-post" : "reply-post");
                article.setAttribute("data-role", post.role);
                article.setAttribute("data-is-op", isOp ? "true" : "false");

                const header = document.createElement("div");
                header.className = "post-header";

                const author = document.createElement("span");
                author.className = "author-name";
                author.textContent = post.author;

                const badge = document.createElement("span");
                badge.className = "role-badge " + (isOp ? "op-badge" : "reply-badge");
                badge.textContent = post.badge;

                const num = document.createElement("span");
                num.className = "post-number";
                num.textContent = post.number;

                header.append(author, badge, num);

                const body = document.createElement("p");
                body.className = "post-body";
                body.textContent = post.body;

                article.append(header, body);
                container.appendChild(article);
              }
            }

            document.getElementById("spa-next-thread").addEventListener("click", (event) => {
              event.preventDefault();
              const target = Number(event.currentTarget.dataset.targetThread || "102");
              spaRouteCount += 1;
              history.pushState({ threadId: target }, "", "/threads/" + target);
              renderThread(target);
            });

            window.addEventListener("popstate", () => {
              const match = window.location.pathname.match(/\\/threads\\/(\\d+)/);
              const target = match ? Number(match[1]) : 101;
              spaRouteCount += 1;
              renderThread(target);
            });

            renderThread(\(initialThreadID));
          </script>
        </body>
        </html>
        """
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let arrayJSON = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arrayJSON.dropFirst().dropLast())
    }
}

extension DCUITestCase {
    func reloadCurrentPage(in app: XCUIApplication) {
        showBrowser(in: app)
        if usesDrawerLayout(app) {
            openForumMenu(in: app)
            let reload = app.buttons["Reload"].firstMatch
            XCTAssertTrue(reload.waitForExistence(timeout: 10), "Reload action is missing from the forum menu.")
            reload.tap()
        } else {
            let reload = app.buttons["Reload"].firstMatch
            XCTAssertTrue(reload.waitForExistence(timeout: 10), "Reload button is missing from the browser bar.")
            reload.tap()
        }
    }

    func turnScriptSwitchOff(_ toggle: XCUIElement) {
        for attempt in 0..<3 {
            guard (toggle.value as? String) != "0" else { return }
            let innerSwitch = toggle.switches.firstMatch
            if innerSwitch.exists && innerSwitch.frame.width > 0 {
                innerSwitch.tap()
            } else if attempt == 0 {
                toggle.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    /// Runs the full M2 acceptance scenario against `FixtureSpaForumServer`:
    /// 1. Prompt `"from now on, show only the original poster on this site"` saves and applies immediately.
    /// 2. Persists across a full browser reload AND across killing and reopening the app.
    /// 3. Re-applies on a client-side SPA `history.pushState` route change without reloading the document.
    /// 4. Turning the script off in `Settings › Scripts` and reloading restores the page to normal.
    func runM2SpaForumAcceptanceFlow(
        launchExtra: [String],
        environment: [String: String] = [:],
        screenshotPrefix: String? = nil
    ) throws {
        let server = FixtureSpaForumServer()
        try server.start()
        defer { server.stop() }

        let boxID = String(UUID().uuidString.prefix(12))

        func makeConfiguredApp(resetBox: Bool) -> XCUIApplication {
            XCUIDevice.shared.orientation = Self.resolved(.portrait)
            let instance = XCUIApplication()
            for (key, value) in environment {
                instance.launchEnvironment[key] = value
            }
            var args = [
                "-dc-skip-onboarding",
                "-dc-browser-agent-scripts-box", boxID,
                "-dc-open", server.thread101URL,
                "-AppleInterfaceStyle", "Light"
            ]
            if resetBox {
                args.append("-dc-browser-agent-reset-scripts-box")
            }
            args.append(contentsOf: launchExtra)
            instance.launchArguments = args
            instance.launch()
            return instance
        }

        // 1. Initial load (before running the agent): both OP and replies are visible.
        let app = makeConfiguredApp(resetBox: true)
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20), "Browser web view did not appear.")
        XCTAssertTrue(webView.staticTexts["Load #1"].waitForExistence(timeout: 15), "Fixture thread #101 did not load.")
        XCTAssertTrue(webView.staticTexts[FixtureSpaForumServer.thread101OP].waitForExistence(timeout: 10))
        XCTAssertTrue(webView.staticTexts[FixtureSpaForumServer.thread101Reply1].waitForExistence(timeout: 10))
        XCTAssertTrue(webView.staticTexts[FixtureSpaForumServer.thread101Reply2].exists)

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(prefix)-1-before")
        }

        // 2. Open the browser agent and say: "from now on, show only the original poster on this site".
        showAssistant(in: app)
        XCTAssertTrue(waitOrDump(any(app, "agentPanel"), timeout: 15, in: app), "Browser agent panel did not open.")
        XCTAssertTrue(any(app, "pageCapabilitiesSeal").waitForExistence(timeout: 10), "This page seal is missing in Agent panel.")

        let promptInput = app.textFields["agentPromptInput"].firstMatch
        XCTAssertTrue(waitForHittable(promptInput, timeout: 10), "Agent prompt input is not hittable.")
        promptInput.tap()
        promptInput.typeText("from now on, show only the original poster on this site")

        let sendButton = app.buttons["agentSendButton"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Agent send button is missing.")
        XCTAssertTrue(sendButton.isEnabled, "Agent send button should be enabled after typing prompt.")
        if sendButton.isHittable {
            sendButton.tap()
        } else {
            sendButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let statusLine = any(app, "agentStatusLine")
        let finished = wait(timeout: 120) {
            guard statusLine.exists else { return false }
            let label = statusLine.label
            return label.contains("Done") || label.contains("Turn failed") || label.contains("Stopped")
        }
        if !finished || !statusLine.label.contains("Done") {
            if let prefix = screenshotPrefix {
                capture("\(prefix)-failure")
            }
            attachTree(app, named: "M2 browser agent failure tree")
            XCTFail("Browser agent did not complete cleanly (status: \(statusLine.exists ? statusLine.label : "missing")).")
            app.terminate()
            return
        }

        let scriptCard = any(app, "agentScriptCard")
        XCTAssertTrue(
            waitOrDump(scriptCard, timeout: 10, in: app),
            "Saved userscript card must appear in the agent conversation."
        )
        let toolRows = app.buttons.matching(identifier: "agentToolRow")
        XCTAssertGreaterThanOrEqual(toolRows.count, 1)
        let rowLabels = (0..<toolRows.count).map { "[\($0 + 1)] \(toolRows.element(boundBy: $0).label)" }
        XCTAssertTrue(
            rowLabels.contains { $0.localizedCaseInsensitiveContains("script_save") || $0.localizedCaseInsensitiveContains("Saved script") },
            "Expected script_save tool call in conversation, got: \(rowLabels)"
        )

        XCTAssertTrue(
            webView.staticTexts[FixtureSpaForumServer.thread101OP].exists,
            "Original poster post must remain visible."
        )
        XCTAssertTrue(
            waitForGone(webView.staticTexts[FixtureSpaForumServer.thread101Reply1], timeout: 8),
            "Non-OP reply #1 should be hidden immediately after saving the script."
        )
        XCTAssertFalse(
            webView.staticTexts[FixtureSpaForumServer.thread101Reply2].exists,
            "Non-OP reply #2 should be hidden immediately after saving the script."
        )

        if let prefix = screenshotPrefix {
            attachText(
                (["Status: \(statusLine.label)"] + rowLabels).joined(separator: "\n"),
                named: "\(prefix)-tool-calls"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(prefix)-2-saved-card")
        }

        // 3. Reload the page: the saved script still applies on a fresh HTTP document load.
        reloadCurrentPage(in: app)
        XCTAssertTrue(webView.staticTexts["Load #2"].waitForExistence(timeout: 15), "Page did not reload from server.")
        XCTAssertGreaterThanOrEqual(server.requestCount(forPath: "/threads/101"), 2)
        XCTAssertTrue(
            webView.staticTexts[FixtureSpaForumServer.thread101OP].waitForExistence(timeout: 10),
            "OP post must remain visible after reload."
        )
        XCTAssertTrue(
            waitForGone(webView.staticTexts[FixtureSpaForumServer.thread101Reply1], timeout: 8),
            "Non-OP reply #1 must stay hidden after reload."
        )
        XCTAssertFalse(
            webView.staticTexts[FixtureSpaForumServer.thread101Reply2].exists,
            "Non-OP reply #2 must stay hidden after reload."
        )

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(prefix)-3-after-reload")
        }

        // 4. Kill and reopen the app: ScriptStore reloads `.user.js` from disk and injects automatically.
        app.terminate()

        let reopenedApp = makeConfiguredApp(resetBox: false)
        let reopenedWebView = reopenedApp.webViews.firstMatch
        XCTAssertTrue(reopenedWebView.waitForExistence(timeout: 20), "Reopened app web view did not appear.")
        XCTAssertTrue(
            reopenedWebView.staticTexts["Load #3"].waitForExistence(timeout: 15),
            "Reopened app did not load fixture thread #101."
        )
        XCTAssertGreaterThanOrEqual(server.requestCount(forPath: "/threads/101"), 3)
        XCTAssertTrue(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread101OP].waitForExistence(timeout: 10),
            "OP post must remain visible after killing and reopening the app."
        )
        XCTAssertTrue(
            waitForGone(reopenedWebView.staticTexts[FixtureSpaForumServer.thread101Reply1], timeout: 8),
            "Non-OP reply #1 must stay hidden after killing and reopening the app."
        )
        XCTAssertFalse(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread101Reply2].exists,
            "Non-OP reply #2 must stay hidden after killing and reopening the app."
        )
        if usesDrawerLayout(reopenedApp) {
            let aiButton = reopenedApp.buttons["aiButton"]
            if waitForBarItem(aiButton, timeout: 10) {
                let value = (aiButton.value as? String) ?? ""
                XCTAssertTrue(
                    value.contains("1 script on this page") || value.contains("1 scripts on this page"),
                    "Expected toolbar badge value to report 1 active script after reopen, got '\(value)'."
                )
            }
        }

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(prefix)-4-after-reopen")
        }

        // 5. SPA route change via `history.pushState` (no document reload): script still applies.
        let preSpaThread102Count = server.requestCount(forPath: "/threads/102")
        let spaLink = reopenedWebView.links["Next thread: Offline Reading"].firstMatch
        XCTAssertTrue(spaLink.waitForExistence(timeout: 10), "SPA route link is missing.")
        spaLink.tap()

        XCTAssertTrue(
            reopenedWebView.staticTexts["Thread #102 · SPA route #2"].waitForExistence(timeout: 10),
            "SPA pushState route did not render thread #102."
        )
        XCTAssertTrue(
            reopenedWebView.staticTexts["Load #3"].exists,
            "SPA navigation should keep Load #3 without reloading the document."
        )
        XCTAssertEqual(
            server.requestCount(forPath: "/threads/102"),
            preSpaThread102Count,
            "SPA pushState navigation must not fetch /threads/102 from the server."
        )
        XCTAssertTrue(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread102OP].waitForExistence(timeout: 10),
            "OP post on SPA route #2 must be visible."
        )
        XCTAssertTrue(
            waitForGone(reopenedWebView.staticTexts[FixtureSpaForumServer.thread102Reply1], timeout: 8),
            "Non-OP reply #1 on SPA route #2 must be hidden by the persisted userscript."
        )
        XCTAssertFalse(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread102Reply2].exists,
            "Non-OP reply #2 on SPA route #2 must be hidden by the persisted userscript."
        )

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(prefix)-5-after-spa-route")
        }

        // 6. Switch the script off in Settings › Scripts (`ScriptManagerView`) and reload: back to normal.
        openSettings(in: reopenedApp)
        let scriptsRow = reopenedApp.buttons["settingsRow-scripts"].firstMatch
        XCTAssertTrue(reveal(scriptsRow, in: reopenedApp, swipes: 4), "Settings › Scripts row is missing.")
        scriptsRow.tap()

        XCTAssertTrue(
            waitOrDump(any(reopenedApp, "scriptManager"), timeout: 10, in: reopenedApp),
            "ScriptManagerView did not open."
        )
        let scriptToggle = reopenedApp.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "scriptToggle-")
        ).firstMatch
        XCTAssertTrue(reveal(scriptToggle, in: reopenedApp, swipes: 4), "Saved script toggle is missing in ScriptManagerView.")
        XCTAssertEqual(scriptToggle.value as? String, "1", "Saved script should start enabled in ScriptManagerView.")

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            capture("\(prefix)-6-script-manager-on")
        }

        turnScriptSwitchOff(scriptToggle)
        XCTAssertTrue(
            wait(timeout: 5) { (scriptToggle.value as? String) == "0" },
            "Script toggle did not switch off in ScriptManagerView."
        )

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            capture("\(prefix)-7-script-manager-off")
        }

        tapNavigationBack(in: reopenedApp)
        closeSettings(in: reopenedApp)

        reloadCurrentPage(in: reopenedApp)
        XCTAssertTrue(
            reopenedWebView.staticTexts["Load #4"].waitForExistence(timeout: 15),
            "Page did not reload after disabling the script."
        )
        XCTAssertTrue(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread102OP].waitForExistence(timeout: 10),
            "OP post must remain visible after disabling the script and reloading."
        )
        XCTAssertTrue(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread102Reply1].waitForExistence(timeout: 10),
            "Non-OP reply #1 must return after disabling the script and reloading."
        )
        XCTAssertTrue(
            reopenedWebView.staticTexts[FixtureSpaForumServer.thread102Reply2].waitForExistence(timeout: 10),
            "Non-OP reply #2 must return after disabling the script and reloading."
        )

        if let prefix = screenshotPrefix {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            capture("\(prefix)-8-back-to-normal")
        }

        reopenedApp.terminate()
    }
}
