import Foundation
import OSLog
import WebKit

/// Which JavaScript execution world `AgentBridge` runs in.
///
/// Per `docs/wukongmind/m0-csp-and-worlds.md`, `.isolated` is the default:
/// it has full DOM access, is invisible to page scripts, reaches the isolated
/// reply handler, and is exempt from the page's `unsafe-eval` and `connect-src`
/// CSP checks. `.page` shares JS globals with the page's own scripts.
enum AgentExecutionEnvironment: String, Codable, CaseIterable, Sendable {
    case page
    case isolated

    static let defaultEnvironment: Self = .isolated
}

/// Output format for `read_page`.
enum PageReadMode: String, Codable, CaseIterable, Sendable {
    case structure
    case text
    case html
}

/// Current page URL and title reported to the browser agent's system prompt.
struct AgentPageMetadata: Equatable, Sendable {
    var url: String
    var title: String

    static let empty = AgentPageMetadata(url: "", title: "")
}

/// Result of running JavaScript through `AgentBridge.runJS`.
struct JSExecutionResult: Equatable, Sendable {
    /// JSON-encoded return value, or `nil` when the script returned `undefined`.
    var valueJSON: String?
    /// Captured `console.log` / `info` / `warn` / `error` / `debug` lines.
    var consoleOutput: [String]
    /// Runtime or syntax error message when execution threw; `nil` on success.
    var error: String?

    var succeeded: Bool { error == nil }
}

/// Result of injecting or updating a stylesheet via `adoptedStyleSheets`.
struct CSSInjectionResult: Equatable, Sendable {
    var sheetID: String
    var appliedRootCount: Int
}

/// Result of waiting for a selector or a fixed duration.
struct WaitForResult: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case selector
        case delay
    }

    var mode: Mode
    var matched: Bool
    var elapsedMs: Int
    var selector: String?
}

enum AgentBridgeError: LocalizedError, Equatable, Sendable {
    case webViewUnavailable
    case invalidSelector(String)
    case selectorNotFound(String)
    case javaScriptFailed(String)
    case timedOut(seconds: Double)
    case invalidWaitArguments

    var errorDescription: String? {
        switch self {
        case .webViewUnavailable:
            return "The browser web view is not available."
        case .invalidSelector(let selector):
            return "Invalid CSS selector '\(selector)'."
        case .selectorNotFound(let selector):
            return "No element matched selector '\(selector)'."
        case .javaScriptFailed(let message):
            return message
        case .timedOut(let seconds):
            let formatted = seconds.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(seconds))
                : String(format: "%.1f", seconds)
            return "JavaScript execution timed out after \(formatted)s."
        case .invalidWaitArguments:
            return "wait_for requires a non-empty 'selector' or a positive 'ms' duration."
        }
    }
}

/// Abstraction over `AgentBridge` so `ToolRegistry` and `AgentLoop` can run in
/// pure unit tests without instantiating a `WKWebView` or simulator host.
protocol AgentPageDriving: Sendable {
    func currentPageMetadata() async -> AgentPageMetadata
    func readPage(mode: PageReadMode, selector: String?, maxLength: Int?) async throws -> String
    func runJS(
        code: String,
        environment: AgentExecutionEnvironment,
        timeout: TimeInterval
    ) async throws -> JSExecutionResult
    func injectCSS(css: String, id: String?) async throws -> CSSInjectionResult
    func waitFor(selector: String?, milliseconds: Int?) async throws -> WaitForResult
}

/// Bridges the browser agent's page tools (`read_page`, `run_js`, `inject_css`,
/// `wait_for`) to `WKWebView`.
///
/// Security invariants (`requirements.md` §8 & `m0-csp-and-worlds.md`):
/// - `WKScriptMessageHandlerWithReply` (`wukongAgent`) is registered **only**
///   in `AgentBridge.isolatedWorld`, never in `.page`, so untrusted page JS
///   cannot see or invoke native agent handlers.
/// - CSS injection uses `CSSStyleSheet` + `replaceSync` + `adoptedStyleSheets`
///   across `document` and open shadow roots (never `<style>` or `style=`), so
///   strict `style-src` policies never block it.
@MainActor
final class AgentBridge: NSObject, AgentPageDriving {
    nonisolated static let isolatedWorldName = "WukongAgent"
    static let isolatedWorld = WKContentWorld.world(name: isolatedWorldName)
    nonisolated static let messageHandlerName = "wukongAgent"
    nonisolated static let defaultJSTimeout: TimeInterval = 10
    nonisolated static let defaultWaitTimeoutMs = 5_000
    nonisolated static let defaultStructureMaxChars = 12_000

    private static let log = Logger(subsystem: AppIdentity.identifierPrefix, category: "agent-bridge")

    weak var webView: WKWebView?
    /// Optional structured reply router for isolated-world scripts (e.g. M2
    /// userscript `GM_*` calls). Built-in `"ping"` and `"pageInfo"` actions are
    /// always handled even when `replyRouter` is `nil`.
    var replyRouter: (([String: Any]) async throws -> Any?)?
    /// The Agent's workspace, reached by `wukong.files` in isolated `run_js` code.
    var workspace: AgentWorkspace?
    /// Tokens of the `run_js` calls running now; the `files` route accepts only
    /// these, so saved userscripts (same world) and the page world can't use it.
    private var activeCallTokens: Set<String> = []

    private let replyMessageHandler = AgentReplyMessageHandler()
    private var nextGeneratedSheetIndex = 0

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        replyMessageHandler.bridge = self
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(
            forName: Self.messageHandlerName,
            contentWorld: Self.isolatedWorld
        )
        controller.addScriptMessageHandler(
            replyMessageHandler,
            contentWorld: Self.isolatedWorld,
            name: Self.messageHandlerName
        )
    }

    func contentWorld(for environment: AgentExecutionEnvironment) -> WKContentWorld {
        switch environment {
        case .page:
            return .page
        case .isolated:
            return Self.isolatedWorld
        }
    }

    func currentPageMetadata() async -> AgentPageMetadata {
        guard let webView else { return .empty }
        let urlString = webView.url?.absoluteString ?? ""
        let title = webView.title ?? ""
        if !urlString.isEmpty || !title.isEmpty {
            return AgentPageMetadata(url: urlString, title: title)
        }
        // Fallback for `loadHTMLString` pages before `webView.title` settles.
        if let raw = try? await callAsyncJS(
            script: "return { url: String(window.location.href || ''), title: String(document.title || '') };",
            arguments: [:],
            world: Self.isolatedWorld,
            timeout: 2
        ) as? [String: Any] {
            return AgentPageMetadata(
                url: (raw["url"] as? String) ?? "",
                title: (raw["title"] as? String) ?? ""
            )
        }
        return .empty
    }

    // MARK: - run_js

    func runJS(
        code: String,
        environment: AgentExecutionEnvironment = .defaultEnvironment,
        timeout: TimeInterval = AgentBridge.defaultJSTimeout
    ) async throws -> JSExecutionResult {
        let effectiveTimeout = timeout > 0 ? timeout : Self.defaultJSTimeout
        let world = contentWorld(for: environment)
        // Isolated calls get the workspace helpers and a token valid only until
        // this call returns or times out.
        let token: String? = (environment == .isolated && workspace != nil) ? UUID().uuidString : nil
        let wrapped = Self.wrappedExecutionScript(userBody: code, withHelpers: token != nil)
        if let token { activeCallTokens.insert(token) }
        defer { if let token { activeCallTokens.remove(token) } }

        let raw: Any?
        do {
            raw = try await callAsyncJS(
                script: wrapped,
                arguments: token.map { ["__wukongCallToken": $0] } ?? [:],
                world: world,
                timeout: effectiveTimeout
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let bridgeError as AgentBridgeError {
            switch bridgeError {
            case .webViewUnavailable, .timedOut:
                throw bridgeError
            case .javaScriptFailed(let message):
                return JSExecutionResult(
                    valueJSON: nil,
                    consoleOutput: [],
                    error: Self.decoratePageWorldCSPHint(message, environment: environment)
                )
            default:
                throw bridgeError
            }
        }

        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return JSExecutionResult(valueJSON: nil, consoleOutput: [], error: nil)
        }

        let consoleLines = (payload["console"] as? [String]) ?? []
        let ok = (payload["ok"] as? Bool) ?? false
        if ok {
            let valueJSON = payload["valueJSON"] as? String
            return JSExecutionResult(valueJSON: valueJSON, consoleOutput: consoleLines, error: nil)
        } else {
            let rawError = (payload["error"] as? String) ?? "JavaScript execution failed."
            let decorated = Self.decoratePageWorldCSPHint(rawError, environment: environment)
            return JSExecutionResult(valueJSON: nil, consoleOutput: consoleLines, error: decorated)
        }
    }

    private static func decoratePageWorldCSPHint(
        _ message: String,
        environment: AgentExecutionEnvironment
    ) -> String {
        guard environment == .page else { return message }
        let triggers = ["EvalError", "Load failed", "Content Security Policy", "unsafe-eval"]
        guard triggers.contains(where: { message.localizedCaseInsensitiveContains($0) }) else {
            return message
        }
        return message + " (Hint: the page's Content Security Policy restricts eval or cross-origin requests in the 'page' world; retry with environment: 'isolated' unless you specifically need page JS globals.)"
    }

    // MARK: - inject_css

    func injectCSS(css: String, id: String? = nil) async throws -> CSSInjectionResult {
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sheetID: String
        if trimmedID.isEmpty {
            nextGeneratedSheetIndex += 1
            sheetID = "wukong-style-\(nextGeneratedSheetIndex)"
        } else {
            sheetID = trimmedID
        }

        let raw = try await callAsyncJS(
            script: Self.injectCSSScript,
            arguments: [
                "css": css,
                "sheetId": sheetID
            ],
            world: Self.isolatedWorld,
            timeout: Self.defaultJSTimeout
        )

        if let dict = raw as? [String: Any] {
            if let errorMessage = dict["error"] as? String, !errorMessage.isEmpty {
                throw AgentBridgeError.javaScriptFailed(errorMessage)
            }
            let count = (dict["appliedRootCount"] as? Int) ?? 1
            return CSSInjectionResult(sheetID: sheetID, appliedRootCount: count)
        }
        return CSSInjectionResult(sheetID: sheetID, appliedRootCount: 1)
    }

    // MARK: - read_page

    func readPage(
        mode: PageReadMode = .structure,
        selector: String? = nil,
        maxLength: Int? = nil
    ) async throws -> String {
        let normalizedSelector = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectorArg: Any = (normalizedSelector?.isEmpty == false) ? normalizedSelector! : NSNull()
        let structureBudget = maxLength ?? Self.defaultStructureMaxChars

        let raw = try await callAsyncJS(
            script: Self.readPageScript,
            arguments: [
                "mode": mode.rawValue,
                "selector": selectorArg,
                "structureBudget": max(512, structureBudget)
            ],
            world: Self.isolatedWorld,
            timeout: Self.defaultJSTimeout
        )

        guard let dict = raw as? [String: Any] else {
            throw AgentBridgeError.javaScriptFailed("Failed to read page content.")
        }

        if let errorKind = dict["errorKind"] as? String {
            let sel = normalizedSelector ?? ""
            switch errorKind {
            case "invalidSelector":
                throw AgentBridgeError.invalidSelector(sel)
            case "notFound":
                throw AgentBridgeError.selectorNotFound(sel)
            default:
                let message = (dict["errorMessage"] as? String) ?? "Failed to read page content."
                throw AgentBridgeError.javaScriptFailed(message)
            }
        }

        let content = (dict["content"] as? String) ?? ""
        if let maxLength, maxLength > 0, content.count > maxLength {
            let total = content.count
            return String(content.prefix(maxLength))
                + "\n...[truncated to max_length=\(maxLength), \(total) characters in total]"
        }
        return content
    }

    // MARK: - wait_for

    func waitFor(selector: String? = nil, milliseconds: Int? = nil) async throws -> WaitForResult {
        let trimmedSelector = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetSelector = trimmedSelector, !targetSelector.isEmpty {
            let timeoutMs = max(1, min(milliseconds ?? Self.defaultWaitTimeoutMs, 60_000))
            let timeoutSeconds = Double(timeoutMs) / 1_000.0 + 2.0
            let raw = try await callAsyncJS(
                script: Self.waitForSelectorScript,
                arguments: [
                    "selector": targetSelector,
                    "timeoutMs": timeoutMs
                ],
                world: Self.isolatedWorld,
                timeout: timeoutSeconds
            )
            guard let dict = raw as? [String: Any] else {
                throw AgentBridgeError.javaScriptFailed("Failed while waiting for selector '\(targetSelector)'.")
            }
            if let errorKind = dict["errorKind"] as? String, errorKind == "invalidSelector" {
                throw AgentBridgeError.invalidSelector(targetSelector)
            }
            let matched = (dict["matched"] as? Bool) ?? false
            let elapsedMs = (dict["elapsedMs"] as? Int) ?? timeoutMs
            return WaitForResult(
                mode: .selector,
                matched: matched,
                elapsedMs: elapsedMs,
                selector: targetSelector
            )
        }

        if let milliseconds, milliseconds > 0 {
            let clampedMs = min(milliseconds, 60_000)
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(clampedMs))
            let elapsed = start.duration(to: .now)
            let elapsedMs = max(
                clampedMs,
                Int(elapsed.components.seconds * 1_000)
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            )
            return WaitForResult(
                mode: .delay,
                matched: true,
                elapsedMs: elapsedMs,
                selector: nil
            )
        }

        throw AgentBridgeError.invalidWaitArguments
    }

    // MARK: - Isolated Reply Handling

    fileprivate func handleIsolatedMessage(
        body: Any,
        isMainFrame: Bool
    ) async -> (Any?, String?) {
        guard isMainFrame else {
            return (nil, "Messages from subframes are not permitted.")
        }
        guard let payload = body as? [String: Any] else {
            return (nil, "Expected an object message payload.")
        }
        let action = (payload["action"] as? String) ?? ""
        switch action {
        case "ping":
            var reply: [String: Any] = [
                "ok": true,
                "world": Self.isolatedWorldName
            ]
            if let echo = payload["echo"] {
                reply["echo"] = echo
            }
            return (reply, nil)
        case "pageInfo":
            let meta = await currentPageMetadata()
            return (["url": meta.url, "title": meta.title], nil)
        case "files":
            return await handleFilesMessage(payload)
        default:
            if let replyRouter {
                do {
                    let value = try await replyRouter(payload)
                    return (value ?? NSNull(), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }
            return (nil, "Unsupported isolated bridge action '\(action)'.")
        }
    }

    /// `wukong.files.write` / `append` from an isolated `run_js` call.
    private func handleFilesMessage(_ payload: [String: Any]) async -> (Any?, String?) {
        guard let token = payload["token"] as? String, activeCallTokens.contains(token) else {
            return (nil, "wukong.files is only available inside the Agent's run_js.")
        }
        guard let workspace else {
            return (nil, "The workspace is unavailable.")
        }
        let op = (payload["op"] as? String) ?? ""
        guard op == "write" || op == "append" else {
            return (nil, "Unsupported wukong.files operation '\(op)'.")
        }
        guard let path = payload["path"] as? String, let text = payload["text"] as? String else {
            return (nil, "wukong.files.\(op) needs a path and text.")
        }
        do {
            let written = try await workspace.write(path: path, content: text, append: op == "append")
            return (["path": written.path, "bytes_written": written.bytesWritten, "size": written.size], nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    // MARK: - Low-level cancellable / timed callAsyncJavaScript

    private func callAsyncJS(
        script: String,
        arguments: [String: Any],
        world: WKContentWorld,
        timeout: TimeInterval
    ) async throws -> Any? {
        try Task.checkCancellation()
        guard let webView else {
            throw AgentBridgeError.webViewUnavailable
        }

        let box = ContinuationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                box.install(continuation)

                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(max(1, Int((timeout * 1_000).rounded()))))
                    guard !Task.isCancelled else { return }
                    box.resume(throwing: AgentBridgeError.timedOut(seconds: timeout))
                }
                box.timeoutTask = timeoutTask

                webView.callAsyncJavaScript(
                    script,
                    arguments: arguments,
                    in: nil,
                    in: world
                ) { result in
                    switch result {
                    case .success(let value):
                        box.resume(returning: value)
                    case .failure(let error):
                        box.resume(throwing: AgentBridgeError.javaScriptFailed(Self.extractJSErrorMessage(error)))
                    }
                }
            }
        } onCancel: {
            box.cancelImmediately()
        }
    }

    private nonisolated static func extractJSErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if let exceptionMessage = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String,
           !exceptionMessage.isEmpty {
            if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int, line > 0 {
                return "JavaScript error (line \(line)): \(exceptionMessage)"
            }
            return exceptionMessage
        }
        return error.localizedDescription
    }
}

// MARK: - Continuation Box & Weak Script Reply Handler

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Any?, Error>?
    private var pendingOutcome: Result<Any?, Error>?
    var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Any?, Error>) {
        lock.lock()
        if let pendingOutcome {
            self.pendingOutcome = nil
            let task = timeoutTask
            timeoutTask = nil
            lock.unlock()
            task?.cancel()
            continuation.resume(with: pendingOutcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: Any?) {
        finish(.success(value))
    }

    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    func cancelImmediately() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Any?, Error>) {
        lock.lock()
        let task = timeoutTask
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            lock.unlock()
            task?.cancel()
            continuation.resume(with: result)
            return
        }
        if pendingOutcome == nil {
            pendingOutcome = result
        }
        lock.unlock()
        task?.cancel()
    }
}

/// Weak wrapper so `WKUserContentController` does not retain `AgentBridge`.
@MainActor
private final class AgentReplyMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: AgentBridge?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let bridge else {
            replyHandler(nil, "Agent bridge is no longer attached.")
            return
        }
        let body = message.body
        let isMainFrame = message.frameInfo.isMainFrame
        Task { @MainActor in
            let (reply, errorMessage) = await bridge.handleIsolatedMessage(
                body: body,
                isMainFrame: isMainFrame
            )
            replyHandler(reply, errorMessage)
        }
    }
}

// MARK: - Injected JavaScript Helpers

extension AgentBridge {
    /// Defined inside each isolated `run_js` call only. `__wukongCallToken` is a
    /// `callAsyncJavaScript` argument, so it never exists outside that call.
    fileprivate static let helpersScript = """
        const wukong = (() => {
          const handler = window.webkit.messageHandlers.wukongAgent;
          const token = __wukongCallToken;
          const files = (op) => (path, text) => handler.postMessage({
            action: "files", op, token, path: String(path), text: String(text)
          });
          return Object.freeze({ files: Object.freeze({ write: files("write"), append: files("append") }) });
        })();
        """

    fileprivate static func wrappedExecutionScript(userBody: String, withHelpers: Bool = false) -> String {
        """
        \(withHelpers ? helpersScript : "")
        const __wukongLogs = [];
        const __wukongFormat = (value) => {
          if (typeof value === "string") return value;
          if (value instanceof Error) return value.stack || value.message || String(value);
          try {
            const encoded = JSON.stringify(value);
            return encoded === undefined ? String(value) : encoded;
          } catch (_) {
            return String(value);
          }
        };
        const __wukongSavedConsole = {};
        for (const level of ["log", "info", "warn", "error", "debug"]) {
          __wukongSavedConsole[level] = console[level];
          console[level] = (...args) => {
            try {
              const prefix = level === "log" ? "" : `[${level}] `;
              __wukongLogs.push(prefix + args.map(__wukongFormat).join(" "));
            } catch (_) {}
            if (typeof __wukongSavedConsole[level] === "function") {
              __wukongSavedConsole[level].apply(console, args);
            }
          };
        }
        const __wukongSerialize = (val) => {
          if (val === undefined) return null;
          try {
            const seen = new WeakSet();
            return JSON.stringify(val, (_key, item) => {
              if (typeof item === "bigint") return item.toString();
              if (typeof item === "object" && item !== null) {
                if (seen.has(item)) return "[Circular]";
                seen.add(item);
                if (typeof Element !== "undefined" && item instanceof Element) {
                  return {
                    tag: item.tagName.toLowerCase(),
                    id: item.id || undefined,
                    className: typeof item.className === "string" && item.className ? item.className : undefined,
                    text: (item.textContent || "").trim().slice(0, 200)
                  };
                }
              }
              return item;
            });
          } catch (_) {
            return JSON.stringify(String(val));
          }
        };
        try {
          const __wukongResult = await (async () => {
        \(userBody)
          })();
          return JSON.stringify({
            ok: true,
            valueJSON: __wukongSerialize(__wukongResult),
            console: __wukongLogs
          });
        } catch (err) {
          const message = err instanceof Error
            ? (err.name && err.message && !err.message.startsWith(err.name)
                ? `${err.name}: ${err.message}`
                : (err.message || String(err)))
            : String(err);
          return JSON.stringify({
            ok: false,
            error: message,
            console: __wukongLogs
          });
        } finally {
          for (const level of Object.keys(__wukongSavedConsole)) {
            console[level] = __wukongSavedConsole[level];
          }
        }
        """
    }

    fileprivate static let injectCSSScript = """
    try {
      const store = (window.__wukongStyleSheets ||= new Map());
      let sheet = store.get(sheetId);
      if (!sheet) {
        sheet = new CSSStyleSheet();
        store.set(sheetId, sheet);
      }
      sheet.replaceSync(css);

      const managedSheets = Array.from(store.values());
      const applyToRoot = (root) => {
        if (!root || !("adoptedStyleSheets" in root)) return 0;
        const existing = Array.from(root.adoptedStyleSheets || []);
        const retained = existing.filter((candidate) => !managedSheets.includes(candidate));
        root.adoptedStyleSheets = retained.concat(managedSheets);
        return 1;
      };

      let appliedRootCount = applyToRoot(document);
      const walkShadows = (node) => {
        if (!node || typeof node.querySelectorAll !== "function") return;
        for (const el of node.querySelectorAll("*")) {
          if (el.shadowRoot) {
            appliedRootCount += applyToRoot(el.shadowRoot);
            walkShadows(el.shadowRoot);
          }
        }
      };
      walkShadows(document.documentElement);
      return { sheetId, appliedRootCount };
    } catch (err) {
      return { error: err instanceof Error ? (err.message || String(err)) : String(err) };
    }
    """

    fileprivate static let waitForSelectorScript = """
    try {
      if (document.querySelector(selector)) {
        return { matched: true, elapsedMs: 0 };
      }
    } catch (_) {
      return { errorKind: "invalidSelector" };
    }

    const startedAt = performance.now();
    return await new Promise((resolve) => {
      let settled = false;
      let observer = null;
      let intervalId = null;
      let timeoutId = null;

      const finish = (matched) => {
        if (settled) return;
        settled = true;
        if (observer) observer.disconnect();
        if (intervalId !== null) clearInterval(intervalId);
        if (timeoutId !== null) clearTimeout(timeoutId);
        resolve({
          matched,
          elapsedMs: Math.max(0, Math.round(performance.now() - startedAt))
        });
      };

      const check = () => {
        try {
          if (document.querySelector(selector)) {
            finish(true);
          }
        } catch (_) {
          finish(false);
        }
      };

      const root = document.documentElement || document;
      if (root) {
        observer = new MutationObserver(check);
        observer.observe(root, {
          childList: true,
          subtree: true,
          attributes: true
        });
      }
      intervalId = setInterval(check, 50);
      timeoutId = setTimeout(() => finish(false), timeoutMs);
      check();
    });
    """

    fileprivate static let readPageScript = """
    let root = document.documentElement || document.body;
    if (typeof selector === "string" && selector.length > 0) {
      try {
        root = document.querySelector(selector);
      } catch (_) {
        return { errorKind: "invalidSelector" };
      }
      if (!root) {
        return { errorKind: "notFound" };
      }
    }
    if (!root) {
      return { content: "" };
    }

    if (mode === "html") {
      return { content: root.outerHTML || "" };
    }

    if (mode === "text") {
      const textRoot = (root === document.documentElement && document.body) ? document.body : root;
      const text = (typeof textRoot.innerText === "string" ? textRoot.innerText : textRoot.textContent) || "";
      return { content: text.replace(/\\n{3,}/g, "\\n\\n").trim() };
    }

    const IGNORED_TAGS = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "META", "LINK", "HEAD"]);
    const LANDMARK_TAGS = new Set(["HEADER", "NAV", "MAIN", "ARTICLE", "SECTION", "ASIDE", "FOOTER", "FORM", "DIALOG"]);
    const LANDMARK_ROLES = new Set(["banner", "navigation", "main", "complementary", "contentinfo", "search", "region", "dialog", "form"]);
    const INTERACTIVE_ROLES = new Set(["button", "link", "tab", "checkbox", "radio", "switch", "menuitem", "option", "combobox", "textbox", "searchbox"]);

    const collapse = (text, cap = 220) => {
      const normalized = String(text || "").replace(/\\s+/g, " ").trim();
      if (normalized.length <= cap) return normalized;
      return normalized.slice(0, cap) + "…";
    };

    const escapeAttr = (val) => String(val).replace(/\\\\/g, "\\\\\\\\").replace(/"/g, '\\\\"');

    const isNoisyToken = (token) => {
      if (!token || token.length > 40) return true;
      if (/^(css|sc|jsx|svelte|tw|emotion|styles?)[-_][a-zA-Z0-9_-]{4,}$/.test(token)) return true;
      if (/^_[a-zA-Z0-9_-]{5,}$/.test(token)) return true;
      if (/[A-Z].*[0-9]|[0-9].*[A-Z]/.test(token) && token.length >= 7) return true;
      if (/^[a-f0-9]{7,}$/i.test(token)) return true;
      return false;
    };

    const stableSelector = (el) => {
      if (!el || el.nodeType !== 1) return "";
      const tag = el.tagName.toLowerCase();
      if (el.id && el.id.length <= 64 && !/^:[a-z0-9]+:$/i.test(el.id)) {
        if (/^[a-zA-Z_-][a-zA-Z0-9_-]*$/.test(el.id)) {
          return `#${el.id}`;
        }
        return `${tag}[id="${escapeAttr(el.id)}"]`;
      }
      for (const attr of ["data-testid", "data-test", "data-qa", "data-cy"]) {
        const val = el.getAttribute(attr);
        if (val && val.length <= 64) {
          return `${tag}[${attr}="${escapeAttr(val)}"]`;
        }
      }
      const nameAttr = el.getAttribute("name");
      if (nameAttr && nameAttr.length <= 64) {
        return `${tag}[name="${escapeAttr(nameAttr)}"]`;
      }
      const ariaLabel = el.getAttribute("aria-label");
      if (ariaLabel && ariaLabel.length <= 48) {
        return `${tag}[aria-label="${escapeAttr(ariaLabel)}"]`;
      }
      const role = el.getAttribute("role");
      if (typeof el.className === "string" && el.className.trim()) {
        const cleanClasses = el.className
          .trim()
          .split(/\\s+/)
          .filter((cls) => /^[a-zA-Z][a-zA-Z0-9_-]*$/.test(cls) && !isNoisyToken(cls))
          .slice(0, 2);
        if (cleanClasses.length > 0) {
          const base = `${tag}.${cleanClasses.join(".")}`;
          if (el.parentElement) {
            const matches = Array.from(el.parentElement.children).filter((sib) => sib.tagName === el.tagName);
            if (matches.length > 1) {
              const idx = matches.indexOf(el) + 1;
              try {
                if (document.querySelectorAll(base).length > 1) {
                  return `${base}:nth-of-type(${idx})`;
                }
              } catch (_) {}
            }
          }
          return base;
        }
      }
      if (role && role.length <= 32) {
        return `${tag}[role="${escapeAttr(role)}"]`;
      }
      if (el.parentElement) {
        const sameTag = Array.from(el.parentElement.children).filter((sib) => sib.tagName === el.tagName);
        if (sameTag.length > 1) {
          return `${tag}:nth-of-type(${sameTag.indexOf(el) + 1})`;
        }
      }
      return tag;
    };

    const isVisible = (el) => {
      if (!el || el.nodeType !== 1) return false;
      if (IGNORED_TAGS.has(el.tagName)) return false;
      if (el.hidden || el.getAttribute("aria-hidden") === "true") return false;
      const style = window.getComputedStyle(el);
      if (!style) return true;
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") {
        return false;
      }
      if (parseFloat(style.opacity || "1") === 0) {
        return false;
      }
      return true;
    };

    const directText = (el) => {
      let parts = [];
      for (const child of el.childNodes) {
        if (child.nodeType === 3) {
          const t = child.nodeValue.replace(/\\s+/g, " ").trim();
          if (t) parts.push(t);
        }
      }
      return parts.join(" ");
    };

    const lines = [];
    lines.push(`Page: ${collapse(document.title || "(untitled)", 160)}`);
    lines.push(`URL: ${window.location.href || ""}`);
    const docHeight = Math.max(
      document.documentElement ? document.documentElement.scrollHeight : 0,
      document.body ? document.body.scrollHeight : 0
    );
    lines.push(`Viewport: ${window.innerWidth}x${window.innerHeight} (scrollY=${Math.round(window.scrollY)}/${docHeight})`);
    if (typeof selector === "string" && selector.length > 0) {
      lines.push(`Scope: ${selector}`);
    }
    lines.push("---");

    let charCount = lines.join("\\n").length;
    let truncatedInternally = false;

    const emit = (depth, line) => {
      if (truncatedInternally) return false;
      const indent = "  ".repeat(Math.min(depth, 6));
      const formatted = indent + line;
      if (charCount + formatted.length + 1 > structureBudget) {
        truncatedInternally = true;
        return false;
      }
      lines.push(formatted);
      charCount += formatted.length + 1;
      return true;
    };

    const describeControl = (el) => {
      const tag = el.tagName.toLowerCase();
      const sel = stableSelector(el);
      const role = el.getAttribute("role");
      const type = (el.getAttribute("type") || "").toLowerCase();
      const label = collapse(
        el.getAttribute("aria-label")
          || (el.labels && el.labels.length ? Array.from(el.labels).map((l) => l.textContent).join(" ") : "")
          || el.getAttribute("placeholder")
          || el.innerText
          || el.textContent
          || "",
        120
      );
      const flags = [];
      if (type) flags.push(`type=${type}`);
      if (role && role !== tag) flags.push(`role=${role}`);
      if (el.disabled || el.getAttribute("aria-disabled") === "true") flags.push("disabled");
      if (el.checked || el.getAttribute("aria-checked") === "true") flags.push("checked");
      if (el.required) flags.push("required");

      if (tag === "input" || tag === "textarea" || tag === "select") {
        if (type === "password") {
          const masked = el.value ? "[masked]" : "";
          if (masked) flags.push(`value=${masked}`);
        } else if (typeof el.value === "string" && el.value.length > 0) {
          flags.push(`value="${collapse(el.value, 80)}"`);
        }
      }
      const meta = flags.length ? ` (${flags.join(", ")})` : "";
      const textPart = label ? ` "${label}"` : "";
      return `[control ${sel}]${meta}${textPart}`;
    };

    const walk = (el, depth) => {
      if (truncatedInternally || !isVisible(el)) return;
      const tag = el.tagName;
      const lower = tag.toLowerCase();
      const role = (el.getAttribute("role") || "").toLowerCase();

      if (/^H[1-6]$/.test(tag)) {
        const text = collapse(el.innerText || el.textContent || "", 180);
        if (text) emit(depth, `[${lower} ${stableSelector(el)}] ${text}`);
        return;
      }

      if (tag === "A" && el.hasAttribute("href")) {
        const rawHref = el.getAttribute("href") || "";
        const text = collapse(el.innerText || el.textContent || el.getAttribute("aria-label") || "", 140);
        const sel = stableSelector(el);
        emit(depth, `[link ${sel}] "${text || rawHref}" -> ${collapse(rawHref, 160)}`);
        return;
      }

      if (
        tag === "BUTTON"
        || tag === "INPUT"
        || tag === "TEXTAREA"
        || tag === "SELECT"
        || tag === "SUMMARY"
        || INTERACTIVE_ROLES.has(role)
        || el.getAttribute("contenteditable") === "true"
      ) {
        emit(depth, describeControl(el));
        return;
      }

      if (tag === "IMG") {
        const alt = collapse(el.getAttribute("alt") || "", 120);
        if (alt) emit(depth, `[img ${stableSelector(el)}] alt="${alt}"`);
        return;
      }

      const isLandmark = LANDMARK_TAGS.has(tag) || LANDMARK_ROLES.has(role);
      let nextDepth = depth;
      if (isLandmark) {
        const label = collapse(el.getAttribute("aria-label") || "", 80);
        const roleNote = role && !LANDMARK_TAGS.has(tag) ? ` role=${role}` : "";
        const labelNote = label ? ` "${label}"` : "";
        if (!emit(depth, `[${lower} ${stableSelector(el)}${roleNote}]${labelNote}`)) return;
        nextDepth = depth + 1;
      } else if (tag === "LI" || tag === "TR" || tag === "ARTICLE") {
        nextDepth = depth + 1;
      }

      const ownText = directText(el);
      if (ownText && el !== document.documentElement && el !== document.body) {
        emit(nextDepth, `[text ${stableSelector(el)}] ${collapse(ownText, 240)}`);
      }

      for (const child of el.children) {
        if (truncatedInternally) break;
        walk(child, nextDepth);
      }
    };

    const startNode = (root === document.documentElement && document.body) ? document.body : root;
    walk(startNode, 0);
    if (truncatedInternally) {
      lines.push("...[structure summary condensed to fit budget; pass selector or mode='text'/'html' for deeper detail]");
    }
    return { content: lines.join("\\n") };
    """
}
