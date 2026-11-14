import Foundation

// MARK: - Page feedback (docs/wukongmind/page-feedback.md, design-m3.md "Page feedback")
//
// Tools that change the page take a small snapshot of it before and after
// they run, and fixed rules (no model call) decide whether the change may
// have broken the page. The result gets a "Page changes" tool note and, on a
// warning, a first note "The page may be broken: <reasons>" (trusted, before
// the untrusted wrapper; `ToolNote.pageFeedback`).

/// The seven numbers of page-feedback.md "How" 1, plus the address they
/// were read at (a changed address skips the comparison).
struct PageStateSnapshot: Codable, Equatable, Sendable {
    var url: String
    /// Characters of visible body text (`innerText`, trimmed).
    var textLength: Int
    /// Document height in CSS pixels.
    var documentHeight: Int
    /// Whether the page itself can scroll (taller than the viewport and not
    /// locked with `overflow: hidden`).
    var isScrollable: Bool
    var linkCount: Int
    var formControlCount: Int
    var visibleImageCount: Int
    /// Uncaught errors and unhandled rejections in the page world since the
    /// document started loading.
    var pageErrorCount: Int
}

/// The comparison of a before and an after snapshot, carried on the tool
/// result (and kept for developer mode, task 7).
struct PageFeedbackReport: Codable, Equatable, Sendable {
    var before: PageStateSnapshot
    /// Nil when the page couldn't be read after the tool ran.
    var after: PageStateSnapshot?
    /// The warning reasons, in rule order; empty when nothing matched.
    var reasons: [String]
    /// Kept in memory from before the call so a later verify-before-save can
    /// pair the run's baseline screenshot with the post-reload screenshot.
    var beforeImage: AgentImage? = nil

    private enum CodingKeys: String, CodingKey {
        case before, after, reasons
    }

    static func == (lhs: PageFeedbackReport, rhs: PageFeedbackReport) -> Bool {
        lhs.before == rhs.before && lhs.after == rhs.after && lhs.reasons == rhs.reasons
    }

    var urlChanged: Bool {
        guard let after else { return false }
        return after.url != before.url
    }

    var isWarning: Bool { !reasons.isEmpty }

    /// First line of the result on a warning.
    var warningLine: String? {
        guard isWarning else { return nil }
        return "The page may be broken: \(reasons.joined(separator: "; "))."
    }

    /// Last line of the result, always present.
    var changesLine: String {
        guard let after else {
            return "Page changes: not compared, the page couldn't be read after the change."
        }
        if urlChanged {
            return "Page changes: not compared, the page address changed to \(after.url)."
        }
        let changes = PageFeedbackRules.changedValues(before: before, after: after)
        if changes.isEmpty { return "Page changes: none" }
        return "Page changes: " + changes.joined(separator: "; ")
    }

    /// The changes line as a trusted tool note (`ToolNote.pageFeedback`): a changed address is
    /// only named there, since the URL comes from the page.
    var changesNote: String {
        urlChanged ? "Page changes: not compared, the page address changed (the new address is at the end of the result)."
            : changesLine
    }

    /// The tool's (already saved or truncated) output for the wrapped part: the warning and
    /// changes go before the wrapper as tool notes; only a new address, page text, stays here.
    func decorate(_ output: String) -> String {
        guard urlChanged, let after else { return output }
        let line = "New page address: \(after.url)"
        return output.isEmpty ? line : output + "\n\n" + line
    }
}

enum PageFeedbackRules {
    /// "Dropped by more than half": after < before × this.
    static let dropRatio = 0.5
    /// Below these "before" values a drop isn't counted, so a page with two
    /// words or one link doesn't warn on every small change.
    static let minimumText = 50
    static let minimumHeight = 100
    static let minimumLinks = 2
    static let minimumFormControls = 2

    static func compare(before: PageStateSnapshot, after: PageStateSnapshot?) -> PageFeedbackReport {
        guard let after, after.url == before.url else {
            return PageFeedbackReport(before: before, after: after, reasons: [])
        }
        return PageFeedbackReport(before: before, after: after, reasons: reasons(before: before, after: after))
    }

    static func reasons(before: PageStateSnapshot, after: PageStateSnapshot) -> [String] {
        var reasons: [String] = []
        if droppedByMoreThanHalf(before.textLength, after.textLength, minimum: minimumText) {
            reasons.append("visible text dropped from \(format(before.textLength)) to \(format(after.textLength)) characters")
        }
        if droppedByMoreThanHalf(before.documentHeight, after.documentHeight, minimum: minimumHeight) {
            reasons.append("page height dropped from \(format(before.documentHeight)) to \(format(after.documentHeight))")
        }
        if before.isScrollable && !after.isScrollable {
            reasons.append("the page can no longer scroll")
        }
        if droppedByMoreThanHalf(before.linkCount, after.linkCount, minimum: minimumLinks) {
            reasons.append("links dropped from \(format(before.linkCount)) to \(format(after.linkCount))")
        }
        if droppedByMoreThanHalf(before.formControlCount, after.formControlCount, minimum: minimumFormControls) {
            reasons.append("form controls dropped from \(format(before.formControlCount)) to \(format(after.formControlCount))")
        }
        if after.pageErrorCount > before.pageErrorCount {
            let new = after.pageErrorCount - before.pageErrorCount
            reasons.append(new == 1 ? "a new page error appeared" : "\(new) new page errors appeared")
        }
        return reasons
    }

    /// "text 12,400 → 310", one entry per value that changed.
    static func changedValues(before: PageStateSnapshot, after: PageStateSnapshot) -> [String] {
        var values: [String] = []
        func number(_ name: String, _ old: Int, _ new: Int) {
            if old != new { values.append("\(name) \(format(old)) → \(format(new))") }
        }
        number("text", before.textLength, after.textLength)
        number("height", before.documentHeight, after.documentHeight)
        if before.isScrollable != after.isScrollable {
            values.append("scrollable \(before.isScrollable ? "yes" : "no") → \(after.isScrollable ? "yes" : "no")")
        }
        number("links", before.linkCount, after.linkCount)
        number("form controls", before.formControlCount, after.formControlCount)
        number("images", before.visibleImageCount, after.visibleImageCount)
        number("page errors", before.pageErrorCount, after.pageErrorCount)
        return values
    }

    private static func droppedByMoreThanHalf(_ before: Int, _ after: Int, minimum: Int) -> Bool {
        before >= minimum && Double(after) < Double(before) * dropRatio
    }

    /// 12400 → "12,400", the same in every locale (the model reads it).
    static func format(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return value < 0 ? "-" + grouped : grouped
    }
}

// MARK: - In-page scripts

enum PageFeedbackScripts {
    /// Page-world global the error counter keeps (non-enumerable, read-only).
    static let errorCounterName = "__wukongPageErrorCount"

    /// Document-start script in the page world, where page errors and
    /// unhandled rejections fire. The `error` listener is not capturing, so
    /// failed image or script loads (which don't bubble) aren't counted.
    static let errorCounterSource = """
    (() => {
      if (Object.prototype.hasOwnProperty.call(window, '\(errorCounterName)')) { return; }
      let count = 0;
      try {
        Object.defineProperty(window, '\(errorCounterName)', {
          get() { return count; },
          enumerable: false,
          configurable: false
        });
      } catch (_) { return; }
      window.addEventListener('error', () => { count += 1; });
      window.addEventListener('unhandledrejection', () => { count += 1; });
    })();
    """

    /// Read in the page world with `evaluateJavaScript`.
    static let errorCounterRead = "(typeof window.\(errorCounterName) === 'number') ? window.\(errorCounterName) : 0"

    /// The fixed snapshot function, run in the isolated world
    /// (`callAsyncJavaScript` body). The page error count is read separately.
    static let snapshotFunction = """
    const doc = document;
    const body = doc.body;
    const root = doc.scrollingElement || doc.documentElement;
    const viewport = window.innerHeight || (doc.documentElement ? doc.documentElement.clientHeight : 0) || 0;
    const height = Math.max(
      root ? root.scrollHeight : 0,
      body ? body.scrollHeight : 0,
      doc.documentElement ? doc.documentElement.scrollHeight : 0
    );
    const overflowOf = (el) => {
      if (!el) { return 'visible'; }
      try { return getComputedStyle(el).overflowY || 'visible'; } catch (_) { return 'visible'; }
    };
    const locked = (value) => value === 'hidden' || value === 'clip';
    const htmlOverflow = overflowOf(doc.documentElement);
    const bodyOverflow = overflowOf(body);
    let scrollable = height > viewport + 1;
    if (locked(htmlOverflow) || (htmlOverflow === 'visible' && locked(bodyOverflow))) {
      scrollable = false;
    }
    let text = 0;
    if (body) {
      try { text = String(body.innerText || '').trim().length; } catch (_) { text = 0; }
    }
    const links = doc.querySelectorAll('a[href]').length;
    const controls = doc.querySelectorAll('input:not([type="hidden"]), select, textarea, button').length;
    let images = 0;
    for (const img of Array.from(doc.images || [])) {
      if (img.offsetWidth > 0 && img.offsetHeight > 0 && img.getClientRects().length > 0) {
        let visible = true;
        try { visible = getComputedStyle(img).visibility !== 'hidden'; } catch (_) {}
        if (visible) { images += 1; }
      }
    }
    return {
      url: String(window.location.href || ''),
      text: text,
      height: Math.round(height),
      scrollable: scrollable,
      links: links,
      controls: controls,
      images: images
    };
    """

    /// Builds a snapshot from the snapshot function's reply.
    static func snapshot(from raw: Any?, pageErrorCount: Int) -> PageStateSnapshot? {
        guard let dict = raw as? [String: Any] else { return nil }
        func int(_ key: String) -> Int {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double, value.isFinite { return Int(value) }
            if let value = dict[key] as? NSNumber { return value.intValue }
            return 0
        }
        return PageStateSnapshot(
            url: (dict["url"] as? String) ?? "",
            textLength: int("text"),
            documentHeight: int("height"),
            isScrollable: (dict["scrollable"] as? Bool) ?? false,
            linkCount: int("links"),
            formControlCount: int("controls"),
            visibleImageCount: int("images"),
            pageErrorCount: pageErrorCount
        )
    }
}

// MARK: - Wrapping page-changing tools

extension ToolRegistry {
    /// Captures the post-change visible screenshot and pairs it with `beforeImage`
    /// when a warning or failed verification fires (`design-m3.md`, "Screenshots on a warning").
    static func warningScreenshots(
        beforeImage: AgentImage?,
        bridge: AgentPageDriving
    ) async -> [AgentImage] {
        var images: [AgentImage] = []
        if let beforeImage {
            images.append(beforeImage)
        }
        if let afterImage = try? await bridge.screenshot(area: .visible).image {
            images.append(afterImage)
        }
        return images
    }

    /// Wraps a page-changing tool's `execute`: snapshot before, run, snapshot
    /// after, and attach the comparison. When `supportsImageInput` is true, a
    /// visible-area screenshot from before the call stays in memory and is
    /// attached alongside an after screenshot only when a warning fires.
    static func withPageFeedback(
        bridge: AgentPageDriving,
        supportsImageInput: Bool = false,
        _ execute: @escaping @Sendable ([String: JSONValue]) async throws -> ToolExecutionOutput
    ) -> @Sendable ([String: JSONValue]) async throws -> ToolExecutionOutput {
        { args in
            let before = await bridge.pageSnapshot()
            let beforeImage: AgentImage? = (supportsImageInput && before != nil)
                ? (try? await bridge.screenshot(area: .visible).image)
                : nil
            var output = try await execute(args)
            guard let before else { return output }
            try Task.checkCancellation()
            let after = await bridge.pageSnapshot()
            var report = PageFeedbackRules.compare(before: before, after: after)
            report.beforeImage = beforeImage
            output.pageFeedback = report
            if report.isWarning, supportsImageInput {
                output.images = await warningScreenshots(beforeImage: beforeImage, bridge: bridge)
            }
            return output
        }
    }
}

// MARK: - Attached Context for Broken-Page Suggestion & Auto-Disabled Script Fix

enum PageFeedbackContext {
    /// Short context block attached to the user turn when "This page looks broken" is tapped.
    static func brokenPageBlock(
        snapshot: PageStateSnapshot?,
        activeScripts: [UserScript],
        errorsByScriptID: [String: ScriptRuntimeError]
    ) -> String {
        var lines: [String] = []
        if let snapshot {
            lines.append(
                "Current page snapshot (\(snapshot.url)): text \(snapshot.textLength) chars, height \(snapshot.documentHeight)px, scrollable \(snapshot.isScrollable ? "yes" : "no"), links \(snapshot.linkCount), form controls \(snapshot.formControlCount), images \(snapshot.visibleImageCount), page errors \(snapshot.pageErrorCount)."
            )
        } else {
            lines.append("Current page snapshot: unavailable.")
        }
        if activeScripts.isEmpty {
            lines.append("Active scripts on this page: none.")
        } else {
            lines.append("Active scripts on this page:")
            for script in activeScripts {
                if let err = errorsByScriptID[script.id] {
                    let linePart = err.line.flatMap { $0 > 0 ? " (line \($0))" : nil } ?? ""
                    lines.append("- \(script.name) (id: \(script.id)) — latest error: \(err.message)\(linePart)")
                } else {
                    lines.append("- \(script.name) (id: \(script.id)) — latest error: none")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Short context block attached to the user turn when "Let the Agent fix it" is tapped.
    static func fixScriptBlock(
        script: UserScript,
        latestError: ScriptRuntimeError?
    ) -> String {
        var lines = [
            "Script to fix: \(script.name) (id: \(script.id))"
        ]
        if let latestError {
            let linePart = latestError.line.flatMap { $0 > 0 ? " (line \($0))" : nil } ?? ""
            lines.append("Latest error: \(latestError.message)\(linePart)")
        } else if let reason = script.disabledReason, !reason.isEmpty {
            lines.append("Latest error: \(reason)")
        } else {
            lines.append("Latest error: none recorded")
        }
        if !script.isEnabled {
            lines.append("The script is currently disabled; pass enabled: true in script_update once fixed.")
        }
        return lines.joined(separator: "\n")
    }
}
