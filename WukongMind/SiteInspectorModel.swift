import Foundation

// The site inspector's data and its trial-run rules (design-learn-on-ask.md "Developer mode, part 2"),
// kept apart from the views so they can be tested. Everything here handles untrusted text as data.

/// One row of "Tools on this page".
struct SiteInspectorTool: Identifiable, Equatable {
    enum Kind: Equatable {
        case site
        case script(name: String)
        case learned(slot: SiteToolSlot, scriptName: String, status: SiteSlotStatus)
    }

    var tool: PageTool
    var kind: Kind

    var id: String { tool.prefixedName }
    var learnedSlot: SiteToolSlot? { if case .learned(let slot, _, _) = kind { slot } else { nil } }

    /// A site's own tool warns before every trial run, whatever its hints say. They are the page's claims.
    var warnsBeforeTrial: Bool { tool.source == .site }

    /// The tools of the current page, each classified by who wrote it.
    static func rows(snapshot: PageToolSnapshot, state: SiteToolState?, scripts: [UserScript]) -> [SiteInspectorTool] {
        snapshot.tools.map { tool in
            guard tool.source == .script else { return SiteInspectorTool(tool: tool, kind: .site) }
            let name = scripts.first { $0.id == tool.ownerID }?.name ?? tool.ownerID ?? ""
            if let slot = SiteToolSlot(rawValue: tool.name), let slotState = state?.slot(slot),
               slotState.scriptID == tool.ownerID, slotState.status != .untried {
                return SiteInspectorTool(tool: tool, kind: .learned(slot: slot, scriptName: name, status: slotState.status))
            }
            return SiteInspectorTool(tool: tool, kind: .script(name: name))
        }
    }
}

/// The arguments editor's starting text, drawn from the tool's schema. A junk schema gives `{}`.
enum ToolTrialArguments {
    static let maxDepth = 4
    static let maxProperties = 20

    static func skeleton(schema: JSONValue?) -> String {
        guard case .object? = schema, let value = sample(schema, depth: 0) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func sample(_ schema: JSONValue?, depth: Int) -> Any {
        guard depth < maxDepth, case .object(let keywords)? = schema else { return NSNull() }
        switch keywords["type"]?.stringValue {
        case "object":
            var result: [String: Any] = [:]
            let properties = keywords["properties"]?.objectValue ?? [:]
            for key in properties.keys.sorted().prefix(maxProperties) { result[key] = sample(properties[key], depth: depth + 1) }
            return result
        case "array": return [Any]()
        case "string": return ""
        case "integer", "number": return 0
        case "boolean": return false
        default: return NSNull()
        }
    }

    /// The JSON object the person typed, or nil when it isn't one.
    static func parse(_ text: String) -> [String: JSONValue]? {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value.objectValue
    }
}

/// What one trial run produced.
struct ToolTrialOutcome: Equatable {
    var text: String
    var isError: Bool
    var byteCount: Int
    var durationMs: Double
}

/// Runs a tool on the open page, straight through the bridge: no run budget, no effect on the Agent's
/// tool list. The confirmation lives in the view; every run, allowed or failed, writes one audit line.
@MainActor
enum ToolTrialRunner {
    static func run(
        _ tool: SiteInspectorTool, arguments: [String: JSONValue], host: String, pageURL: String?,
        bridge: PageToolBridge, auditLog: AuditLog, secrets: [String]
    ) async -> ToolTrialOutcome {
        let argsJSON = JSONValue.encodeCompactJSON(arguments)
        let start = Date()
        let result = await bridge.callTool(prefixedName: tool.tool.prefixedName, arguments: arguments)
        let outcome: ToolTrialOutcome
        switch result {
        case .success(let ok):
            outcome = ToolTrialOutcome(text: prettyJSON(ok.json), isError: false, byteCount: ok.byteCount, durationMs: ok.durationMs)
        case .failure(let failure):
            outcome = ToolTrialOutcome(text: failure.message, isError: true, byteCount: failure.message.utf8.count, durationMs: failure.durationMs)
        }
        auditLog.append(.toolTrial(
            host: host, tool: tool.tool.prefixedName, argumentsJSON: argsJSON, time: start, pageURL: pageURL,
            durationMs: Int(outcome.durationMs), resultBytes: outcome.isError ? nil : outcome.byteCount,
            errorMessage: outcome.isError ? outcome.text : nil, secrets: secrets
        ))
        return outcome
    }

    static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }
}

/// "Check against the shape": the nine verification steps on a learned reader's own test URLs.
/// It reads the slot's state and changes none: no log entry, no repair count, no status.
enum SiteShapeCheck {
    @MainActor
    static func run(
        slot: SiteToolSlot, script: UserScript, state: SiteToolState, openPageURL: String,
        bridge: AgentPageDriving, pageToolBridge: PageToolBridge, scriptStore: ScriptStore
    ) async -> SiteToolVerificationReport {
        var urls = state.slot(slot).testURLs
        // A thread reader is checked on the open thread too, as when it was learned.
        if slot == .readTopic, !urls.contains(openPageURL),
           let patterns = try? SiteToolVerifier.validateSubMatchPatterns(state.threadMatch, label: "thread_match", siteHost: state.host).get(),
           patterns.contains(where: { $0.matches(urlString: openPageURL) }) {
            urls.append(openPageURL)
        }
        return await SiteToolVerifier.verify(
            candidate: script, providedSlots: [slot], siteHost: state.host, openPageURL: openPageURL,
            rawTestURLs: urls, existingState: state, bridge: bridge, pageToolBridge: pageToolBridge, scriptStore: scriptStore
        )
    }
}

/// The learning log's rows and the "Forget this site" reset.
enum SiteInspectorState {
    /// Forgetting clears what the app learned for the host (slots, checks and the retry wait) and keeps one line
    /// saying so. The saved scripts stay: they are deleted in Scripts.
    static func forget(host: String, store: SiteToolStateStore, now: Date = Date()) {
        var fresh = SiteToolState(host: host)
        fresh.appendLog(SiteLogEntry(kind: .forgotten, date: now))
        try? store.save(fresh)
    }
}

#if DEBUG
extension SiteToolState {
    /// `-dc-site-inspector-seed`: a learned site for the screenshots and the UI test of the inspector
    /// (a learned thread reader, a broken list reader, a failed search), as in the artboards.
    static func inspectorSeed(host: String, now: Date = Date()) -> SiteToolState {
        let steps: [SiteVerificationStepResult] = [
            .init(step: 1, name: "Registered", status: .passed), .init(step: 2, name: "Real arguments", status: .passed, detail: "2 threads"),
            .init(step: 3, name: "Strict shape", status: .passed), .init(step: 4, name: "Thread sanity", status: .passed, detail: "46, 12 posts"),
            .init(step: 5, name: "List sanity", status: .skipped, detail: "thread only"), .init(step: 6, name: "Not constant", status: .passed),
            .init(step: 7, name: "Faithful", status: .passed, detail: "#2, #5 on page"), .init(step: 8, name: "Bounded", status: .passed, detail: "1.9 s, 41 KB"),
            .init(step: 9, name: "Stays home", status: .passed, detail: "no other host")
        ]
        var state = SiteToolState(host: host)
        let check = SiteSlotCheck(date: now, url: "https://\(host)/thread-48211-1.html", result: "verified on 2 threads: 46 and 12 posts", counts: [46, 12], durationMs: 2_400, steps: steps)
        state.setSlot(SiteSlotState(status: .learned, scriptID: "seed.reader", verifiedAt: now, lastCheck: check), for: .readTopic)
        state.setSlot(SiteSlotState(status: .broken, scriptID: "seed.reader", repairFailures: 1,
                                    failure: SiteSlotFailure(code: .shape, date: now)), for: .listLatest)
        state.setSlot(SiteSlotState(status: .failed, failure: SiteSlotFailure(code: .gaveUp, date: now,
                                    agentReason: "The search form posts to /search.php and returns the login page for guests.")), for: .searchForum)
        state.appendLog(SiteLogEntry(kind: .failed, slot: .searchForum, date: now.addingTimeInterval(-3_000)))
        state.appendLog(SiteLogEntry(kind: .learned, slot: .readTopic, date: now.addingTimeInterval(-2_000)))
        state.appendLog(SiteLogEntry(kind: .broken, slot: .listLatest, date: now.addingTimeInterval(-1_000)))
        return state
    }
}
#endif
