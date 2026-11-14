import Foundation

// MARK: - Page feedback (docs/wukongmind/page-feedback.md, design-m3.md "Page feedback")
//
// Tools that change the page take a small snapshot of it before and after
// they run, and fixed rules (no model call) decide whether the change may
// have broken the page. The result text gets a "Page changes" line and, on a
// warning, a first line "The page may be broken: <reasons>".

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

    /// Adds the lines around a tool's (already saved or truncated) output:
    /// the warning first, the changes last.
    func decorate(_ output: String) -> String {
        var parts: [String] = []
        if let warningLine { parts.append(warningLine) }
        if !output.isEmpty { parts.append(output) }
        parts.append(changesLine)
        return parts.joined(separator: "\n\n")
    }
}

/// The thresholds and the comparison, in one place (page-feedback.md "How" 3
/// and 8). They are a starting point, to be tuned after the trial.
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
    /// Wraps a page-changing tool's `execute`: snapshot before, run, snapshot
    /// after, and attach the comparison. With no snapshot (a driver that
    /// can't take one, or a page that can't be read) the output is unchanged.
    static func withPageFeedback(
        bridge: AgentPageDriving,
        _ execute: @escaping @Sendable ([String: JSONValue]) async throws -> ToolExecutionOutput
    ) -> @Sendable ([String: JSONValue]) async throws -> ToolExecutionOutput {
        { args in
            let before = await bridge.pageSnapshot()
            var output = try await execute(args)
            guard let before else { return output }
            try Task.checkCancellation()
            let after = await bridge.pageSnapshot()
            output.pageFeedback = PageFeedbackRules.compare(before: before, after: after)
            return output
        }
    }
}
