import Foundation

// Invalidation and repair for learned readers (`design-learn-on-ask.md` "Invalidation and repair"):
// the failure kinds after a call fails the light check, the `broken` slot with its repair block,
// the full check, and the count of runs that ended with the slot still broken.

/// Slot state changes after a failure or a check. Every change is in app code, never the script's.
@MainActor
enum LearnedSiteRepair {
    static let maxRepairFailures = 3

    /// A `tool` failure: the slot goes from `learned` to `broken`, the error joins the script's list,
    /// and a repair run for this script is armed (M4's rules). Returns the repair block.
    static func breakSlot(
        _ slot: SiteToolSlot, script: UserScript, learned: LearnedSiteContext, scriptStore: ScriptStore,
        message: String, taskID: String?
    ) -> String {
        let url = learned.stateStore?.state(forHost: learned.host)?.slot(slot).testURLs.first
        scriptStore.recordError(scriptID: script.id, message: message, url: url)
        if let store = learned.stateStore {
            _ = try? store.update(host: learned.host) { state in
                var s = state.slot(slot)
                guard s.status != .failed else { return }
                if s.status != .broken { state.appendLog(SiteLogEntry(kind: .broken, slot: slot, date: Date(), taskID: taskID)) }
                s.status = .broken
                state.setSlot(s, for: slot)
            }
        }
        learned.scope.brokenSlots.insert(slot)
        let request = ScriptRepair.request(for: script, in: scriptStore, currentPageURL: url.flatMap(URL.init(string:)))
        if learned.scope.repairState?.target.scriptID != script.id {
            learned.scope.repairState = ScriptRepairRunState(target: request.target)
        }
        return request.attachedBlock
    }

    /// The full check passed: the slot is trusted again, and the saved hash is the script's own.
    static func markVerified(
        _ slot: SiteToolSlot, script: UserScript, report: SiteToolVerificationReport, learned: LearnedSiteContext, taskID: String?
    ) {
        _ = try? learned.stateStore?.update(host: learned.host) { state in
            var s = state.slot(slot)
            let wasBroken = s.status == .broken
            s.status = .learned; s.scriptHash = SiteToolVerifier.scriptTextHash(for: script)
            s.verifiedAt = Date(); s.failure = nil
            if wasBroken { s.repairFailures = 0; state.appendLog(SiteLogEntry(kind: .repaired, slot: slot, date: Date(), taskID: taskID)) }
            if let v = report.slots[slot] {
                if !v.testURLs.isEmpty { s.testURLs = v.testURLs }
                s.postStarts = v.postStarts
                s.lastCheck = SiteSlotCheck(date: Date(), url: v.primaryURL, result: v.summary, counts: v.counts, durationMs: v.durationMs)
            }
            state.setSlot(s, for: slot)
        }
        learned.scope.brokenSlots.remove(slot)
    }

    /// The app turned the script off (three page loads with an error, or three failed repairs):
    /// the slot is `failed` with that code, and `scriptID` stays set.
    static func markFailedByApp(_ slot: SiteToolSlot, script: UserScript, learned: LearnedSiteContext, taskID: String?) {
        _ = try? learned.stateStore?.update(host: learned.host) { state in
            var s = state.slot(slot)
            guard s.status != .failed else { return }
            let now = Date()
            s.status = .failed
            s.failure = SiteSlotFailure(code: SiteFailureCode.fromDisabledReason(script.disabledReason), date: now)
            state.setSlot(s, for: slot)
            state.appendLog(SiteLogEntry(kind: .turnedOff, slot: slot, date: now, taskID: taskID))
        }
    }

    /// One failed repair per slot that is still `broken` at the end of a run; the third turns the
    /// script off with `repair_3` saved as its reason, and the 14-day rule starts.
    static func finishRun(learned: LearnedSiteContext, scriptStore: ScriptStore, taskID: String?) {
        let slots = learned.scope.brokenSlots
        learned.scope.brokenSlots = []
        learned.scope.repairState = nil
        guard let store = learned.stateStore, !slots.isEmpty else { return }
        for slot in slots.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let current = store.state(forHost: learned.host)?.slot(slot), current.status == .broken else { continue }
            let exhausted = current.repairFailures + 1 >= maxRepairFailures
            _ = try? store.update(host: learned.host) { state in
                var s = state.slot(slot)
                s.repairFailures += 1
                if exhausted {
                    let now = Date()
                    s.status = .failed
                    s.failure = SiteSlotFailure(code: .repair3, date: now)
                    state.appendLog(SiteLogEntry(kind: .failed, slot: slot, date: now, taskID: taskID))
                }
                state.setSlot(s, for: slot)
            }
            if exhausted, let id = current.scriptID {
                scriptStore.disableForLibraryFailure(id: id, reason: SiteFailureCode.repair3.rawValue)
            }
        }
    }
}

extension ToolRegistry {
    /// This call's repair rules: the run's own, else the one a broken slot armed.
    func currentRepairState() async -> ScriptRepairRunState? {
        if let repairState { return repairState }
        guard let scope = learnedSite?.scope else { return nil }
        return await MainActor.run { scope.repairState }
    }

    static let serviceFailureText = "Error: The site isn't answering the way it should (it may be offline, busy or asking to sign in), "
        + "so this could not be read. The saved reading tool is fine and was not changed; tell the user."
    static let pageFailureText = "Error: This address did not read as a thread, though the reading tool still reads other threads "
        + "of this site. Check the address."

    /// A call failed the light check: say whose fault it was, and for a `tool` failure roll the slot back.
    static func learnedFailure(
        slot: SiteToolSlot, message: String, scriptID: String, requested: URL? = nil, readerSaidService: Bool = false,
        learned: LearnedSiteContext, context: AgentToolContext, callContext: ToolCallContext
    ) async -> ToolExecutionOutput {
        let state = learned.stateStore?.state(forHost: learned.host) ?? learned.state
        let classifier = learnedClassifier(slot: slot, scriptID: scriptID, state: state, learned: learned, context: context)
        let kind = await classifier.classify(slot: slot, state: state.slot(slot), requested: requested, readerSaidService: readerSaidService)
        switch kind {
        case .service: return ToolExecutionOutput(content: serviceFailureText, summary: "Site trouble", isError: true)
        case .page: return ToolExecutionOutput(content: pageFailureText, summary: "Not a thread", isError: true)
        case .tool:
            let block: String? = await MainActor.run {
                context.scriptStore.script(id: scriptID).map {
                    LearnedSiteRepair.breakSlot(slot, script: $0, learned: learned, scriptStore: context.scriptStore, message: message, taskID: callContext.taskID)
                }
            }
            return ToolExecutionOutput(
                content: "Error: \(message)" + (block.map { "\n\n\($0)" } ?? ""),
                summary: "Reading tool broken", isError: true, notes: [.slotBroken]
            )
        }
    }

    private static func learnedClassifier(
        slot: SiteToolSlot, scriptID: String, state: SiteToolState, learned: LearnedSiteContext, context: AgentToolContext
    ) -> SiteFailureClassifier {
        let client = context.network
        let patterns = state.threadMatch.compactMap { try? MatchPattern.parse($0) }
        return SiteFailureClassifier(
            host: learned.host, threadMatch: patterns,
            fetch: { url in
                guard let client else { return SiteProbeResult(status: 200, finalURL: url) }
                guard let response = try? await client.send(AgentHTTPRequest(url: url, sendCookies: true, maxBytes: 1_000_000, timeout: 15)) else {
                    return SiteProbeResult(status: nil)
                }
                return SiteProbeResult(status: response.status, finalURL: response.finalURL, html: response.text ?? "")
            },
            readerReads: { url in
                let call = await callLearnedReader(
                    slot: .readTopic, scriptID: scriptID, payload: ["url": .string(url.absoluteString), "page": .int(1)],
                    learned: learned, shapeNoun: "thread", as: ThreadShape.self
                )
                guard let posts = call.envelope?.shape.posts else { return false }
                return !posts.isEmpty && posts.allSatisfy { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        )
    }

    /// The full check (the verifier's steps on the slot's saved test URLs) for a `broken` slot on every call,
    /// and once per slot for a script whose text no longer matches the hash saved at verification.
    /// Returns a failure result to hand back, or nil when the call may go on.
    static func learnedFullCheck(
        slot: SiteToolSlot, scriptID: String, learned: LearnedSiteContext, context: AgentToolContext, callContext: ToolCallContext
    ) async -> ToolExecutionOutput? {
        let state = learned.stateStore?.state(forHost: learned.host) ?? learned.state
        let slotState = state.slot(slot)
        guard let script = await MainActor.run(body: { context.scriptStore.script(id: scriptID) }) else { return nil }
        guard slotState.status == .broken || slotState.scriptHash.map({ $0 != SiteToolVerifier.scriptTextHash(for: script) }) == true else { return nil }
        let report = await SiteToolVerifier.verify(
            candidate: script, providedSlots: [slot], siteHost: learned.host, openPageURL: "https://\(learned.host)/",
            rawTestURLs: slotState.testURLs, existingState: state, bridge: context.bridge,
            pageToolBridge: learned.pageToolBridge, scriptStore: context.scriptStore
        )
        guard report.passed else {
            return await learnedFailure(
                slot: report.failedSlot ?? slot, message: report.reason ?? "the full check failed", scriptID: script.id,
                learned: learned, context: context, callContext: callContext
            )
        }
        await MainActor.run { LearnedSiteRepair.markVerified(slot, script: script, report: report, learned: learned, taskID: callContext.taskID) }
        return nil
    }
}
