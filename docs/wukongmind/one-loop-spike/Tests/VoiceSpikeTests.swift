import WebKit
import XCTest

// One loop voice spike (design-one-loop.md, task 5). Each test answers one of the six questions
// against real Gemini Live and writes results/<question>.json with every session's event log.

func json<T: Encodable>(_ value: T) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
}

@MainActor
final class VoiceSpikeTests: XCTestCase {
    var rows: [JSONValue] = []

    override func setUp() async throws {
        try XCTSkipIf(LiveClient.apiKey.isEmpty, "SPIKE_GEMINI_KEY is not set")
        rows = []
    }

    func write(_ name: String, _ extra: [String: JSONValue] = [:]) throws {
        let dir = ProcessInfo.processInfo.environment["SPIKE_OUT"] ?? NSTemporaryDirectory()
        var root: [String: JSONValue] = ["question": .string(name), "date": .string(ISO8601DateFormatter().string(from: Date())),
                                         "model": .string(GeminiLive.model), "rows": .array(rows)]
        for (key, value) in extra { root[key] = value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.object(root)).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).json"))
    }

    func row(_ fields: [String: JSONValue], _ client: LiveClient?) {
        var fields = fields
        if let client { fields["events"] = json(client.events) }
        rows.append(.object(fields))
        print("SPIKE \(fields.filter { $0.key != "events" })")
    }

    func session(_ declarations: [JSONValue], instructions: String = SpikeTools.instructions(), note: String? = SpikeTools.screenNote,
                 handle: String? = nil) async -> (LiveClient, Bool) {
        let client = LiveClient()
        let ok = await client.connect(setup: try! LiveClient.setupFrame(instructions: instructions, declarations: declarations, handle: handle))
        if ok, let note { client.note(note) }
        return (client, ok)
    }

    var voiceSet: [JSONValue] { SpikeTools.voice.map { SpikeTools.declaration($0) } }

    // MARK: Canned results (the shapes VoiceToolBridge.response sends today)

    static let briefingAnswer = "Most people here like the N100 for a home server: it idles around 6 watts, and they recommend 16 GB of RAM with Proxmox. A few warn that its two SATA ports limit storage."

    func canned(_ call: GeminiLive.FunctionCall) -> ([String: JSONValue], GeminiLive.Scheduling) {
        switch call.name {
        case "browse_open", "browse_move", "browse_focus":
            return (["status": "moved", "shown": "Post 37 by dave (accepted solution)",
                     "content": "Rolling back to 5.1.4 fixed it for me; the fan curve setting was reset by 5.2.",
                     "message": "Say in a few words where you are and give the gist. It's on screen: don't read it out."], .whenIdle)
        case "read_post", "read_topic":
            return (["status": "read", "shown": "Post 20 by carol",
                     "content": "I set the fan curve back to Silent in the BIOS after 5.2 and it has been quiet for a week.",
                     "message": "Answer the user from this text only."], .whenIdle)
        case "search_forum", "search_comments", "list_latest":
            return (["status": "found", "shown": "3 hits", "hits": [
                "1. Firmware 5.2 rollback guide (bob)", "2. Fan curve reset after update (erin)", "3. 5.2 changelog discussion (frank)"],
                     "message": "The hits are on screen as numbered cards."], .whenIdle)
        case "summarize_topic":
            return (["status": "summarized", "shown": "Summary of Fan noise after firmware 5.2, 84 posts",
                     "content": "1. Firmware 5.2 resets the fan curve to Performance (#3, #12). 2. Rolling back to 5.1.4 or setting the curve to Silent fixes it (#37). 3. The vendor promised a fix in 5.3 (#80).",
                     "message": "The summary card is on screen. Give the gist in two sentences."], .whenIdle)
        case "read_aloud":
            return (["status": "started", "shown": "Reading aloud: Fan noise after firmware 5.2, about 2 minutes",
                     "message": "Tell the user in a few words that it's playing."], .whenIdle)
        case "watch_topic":
            return (["status": "following", "shown": "Following Fan noise after firmware 5.2", "message": "Confirm in a few words."], .whenIdle)
        case "hand_off_to_agent":
            if call.args["action"]?.stringValue == "cancel" {
                return (["status": "cancelled", "shown": "Stopped.", "message": "Confirm in a few words that it stopped."], .whenIdle)
            }
            return (["status": "started", "shown": "The Agent is working on it in the conversation.",
                     "message": "You have already acknowledged it, so say nothing now. The answer arrives as a briefing; don't call hand_off_to_agent again for this request."], .silent)
        case "end": return (["status": "ended"], .silent)
        case "inject_css": return (["status": "applied", "shown": "Style applied.", "message": "Tell the user in a few words."], .whenIdle)
        default: return (["status": "ok", "shown": "Done."], .whenIdle)
        }
    }

    /// Answers every call with its canned result until the model stops calling; returns the call names.
    func drive(_ client: LiveClient, maxCalls: Int = 4, respond: ((GeminiLive.FunctionCall) -> ([String: JSONValue], GeminiLive.Scheduling))? = nil) async -> [String] {
        var names: [String] = []
        var index = client.calls.count
        while names.count < maxCalls, let call = await client.nextCall(after: index) {
            index += 1
            names.append(call.name)
            let (response, scheduling) = (respond ?? canned)(call)
            client.respond(call, response, scheduling)
            if call.name == "end" || (call.name == "hand_off_to_agent" && scheduling == .silent) { break }
        }
        let answered = client.now
        _ = await client.wait(8) { (client.turnCompleteTimes.last ?? 0) > answered }
        return names
    }

    // MARK: Q1 Schema

    func testQ1Schema() async throws {
        let probes: [(String, JSONValue?, String)] = [
            ("lowercase-types", ["type": "object", "properties": ["q": ["type": "string", "description": "Words."]]], "parameters"),
            ("additionalProperties", ["type": "OBJECT", "properties": ["q": ["type": "STRING"]], "additionalProperties": false], "parameters"),
            ("minLength", ["type": "OBJECT", "properties": ["q": ["type": "STRING", "minLength": 1]]], "parameters"),
            ("minimum-maximum", ["type": "OBJECT", "properties": ["n": ["type": "INTEGER", "minimum": 1, "maximum": 500_000]]], "parameters"),
            ("enum", ["type": "OBJECT", "properties": ["m": ["type": "STRING", "enum": ["a", "b"]]]], "parameters"),
            ("array-of-integers", ["type": "OBJECT", "properties": ["posts": ["type": "ARRAY", "items": ["type": "INTEGER"]]]], "parameters"),
            ("nested-object", ["type": "OBJECT", "properties": ["range": ["type": "OBJECT", "properties": ["from": ["type": "INTEGER"], "to": ["type": "INTEGER"]], "required": ["from"]]]], "parameters"),
            ("object-without-properties", ["type": "OBJECT", "properties": ["opts": ["type": "OBJECT"]]], "parameters"),
            ("empty-parameters-object", ["type": "OBJECT", "properties": [:]], "parameters"),
            ("no-parameters", nil, "parameters"),
            ("raw-inputSchema-as-parameters", SpikeTools.voice[4].objectValue!["inputSchema"]!, "parameters"),
            ("raw-inputSchema-as-parametersJsonSchema", SpikeTools.voice[4].objectValue!["inputSchema"]!, "parametersJsonSchema")
        ]
        for (name, schema, field) in probes {
            var declaration: [String: JSONValue] = ["name": "probe", "description": "A test tool. Call it whenever the user asks you to call the probe tool.", "behavior": "NON_BLOCKING"]
            if let schema { declaration[field] = schema }
            let (client, ok) = await session([.object(declaration)], note: nil)
            var called = false
            if ok {
                client.say("Please call the probe tool now, with any arguments.")
                called = await client.nextCall(after: 0, timeout: 15) != nil
            }
            row(["probe": .string(name), "setupOK": .bool(ok), "called": .bool(called),
                 "close": .string(client.close.map { "\($0.code ?? -1) \($0.reason)" } ?? "")], client)
            client.shutdown()
        }
        let sets: [(String, [JSONValue], String)] = [
            ("today-7", SpikeTools.today, SpikeTools.todayInstructions),
            ("voice-12-converted", voiceSet, SpikeTools.instructions()),
            ("fifteen-converted", SpikeTools.fifteen.map { SpikeTools.declaration($0) }, SpikeTools.instructions()),
            ("fifteen-raw", SpikeTools.fifteen.map { SpikeTools.declaration($0, raw: true) }, SpikeTools.instructions())
        ]
        for (name, declarations, instructions) in sets {
            let (client, ok) = await session(declarations, instructions: instructions)
            var call = ""
            if ok {
                client.say("Search this forum for firmware rollback.")
                call = await client.nextCall(after: 0).map { "\($0.name) \(json($0.args))" } ?? ""
            }
            row(["set": .string(name), "tools": .int(Int64(declarations.count)), "setupOK": .bool(ok), "firstCall": .string(call),
                 "close": .string(client.close.map { "\($0.code ?? -1) \($0.reason)" } ?? "")], client)
            client.shutdown()
        }
        // Timing, interleaved ABAB: setup time and first-reply latency, plus the prompt tokens of the first turn.
        for run in 0..<10 {
            let (name, declarations, instructions) = run % 2 == 0 ? sets[0] : sets[2]
            let client = LiveClient()
            let t0 = client.now
            let ok = await client.connect(setup: try LiveClient.setupFrame(instructions: instructions, declarations: declarations))
            let setup = (client.setupCompleteAt ?? -1) - t0
            client.say("Say hello in one short sentence.")
            let said = client.now
            _ = await client.wait(20) { !client.turnCompleteTimes.isEmpty || client.close != nil }
            _ = await client.wait(3) { client.usage != nil }
            let first = client.audioTimes.first.map { $0 - said } ?? -1
            row(["timing": .string(name), "run": .int(Int64(run)), "setupOK": .bool(ok), "setupSeconds": .double(setup),
                 "firstAudioSeconds": .double(first), "promptTokens": .int(Int64(client.usage?.promptTokens ?? -1))], client)
            client.shutdown()
        }
        try write("q1-schema")
    }

    // MARK: Q2 Changing declarations on resume

    func testQ2Resume() async throws {
        let probe = SpikeTools.declaration(SpikeTools.tool("mark_checkpoint", "Mark a checkpoint. Call it whenever the user says checkpoint.", []))
        let changed = voiceSet.filter { $0.objectValue?["name"] != "browse_focus" } + [probe]
        for (variant, second) in [("same-tools", voiceSet), ("changed-tools", changed), ("changed-tools", changed)] {
            let (first, ok) = await session(voiceSet)
            guard ok else { row(["variant": .string(variant), "firstSetupOK": false], first); continue }
            first.say("Please remember the codeword papaya forty-two. Just say OK.")
            _ = await first.wait(20) { !first.turnCompleteTimes.isEmpty }
            _ = await first.wait(15) { first.handle != nil && first.resumable }
            let handle = first.handle
            first.shutdown()
            try? await Task.sleep(for: .seconds(1))
            let (client, resumed) = await session(second, note: nil, handle: handle)
            var memory = "", checkpoint = false, removedToolCalled = false
            if resumed {
                client.say("What was the codeword I asked you to remember?")
                _ = await client.wait(20) { !client.turnCompleteTimes.isEmpty || client.close != nil }
                memory = client.spoken
                client.say("Checkpoint.")
                checkpoint = await client.nextCall(after: 0, timeout: 15)?.name == "mark_checkpoint"
                let count = client.calls.count
                client.say("Only show what the original poster said.")
                removedToolCalled = await client.nextCall(after: count, timeout: 15)?.name == "browse_focus"
            }
            row(["variant": .string(variant), "handle": .bool(handle != nil), "resumedSetupOK": .bool(resumed),
                 "rememberedCodeword": .bool(memory.lowercased().contains("papaya")), "newToolCalled": .bool(checkpoint),
                 "removedToolCalled": .bool(removedToolCalled), "close": .string(client.close.map { "\($0.code ?? -1) \($0.reason)" } ?? "")], client)
            client.shutdown()
        }
        try write("q2-resume")
    }

    // MARK: Q3 Routing

    static let routing: [(String, Set<String>)] = [
        ("Switch to dark mode.", ["hand_off_to_agent"]),
        ("Summarize this, then read it to me.", ["summarize_topic", "read_aloud"]),
        ("Next post.", ["browse_move"]),
        ("What do people here think of the N100 for a home server?", ["hand_off_to_agent"]),
        ("Never mind.", ["hand_off_to_agent:cancel"]),
        ("Take me to the solution.", ["browse_open"]),
        ("Search for firmware rollback.", ["search_forum"]),
        ("Only show what the original poster said.", ["browse_focus"]),
        ("What does post 20 say?", ["read_post"]),
        ("Notify me of new replies to this thread.", ["watch_topic"]),
        ("Go back.", ["browse_move"]),
        ("Thanks, that's all.", ["end"])
    ]

    func testQ3Routing() async throws {
        for rep in 0..<3 {
            for (utterance, expected) in Self.routing {
                let (client, ok) = await session(voiceSet)
                guard ok else { row(["utterance": .string(utterance), "setupOK": false], client); continue }
                var before: [String] = []
                if utterance == "Never mind." {
                    client.say(Self.routing[3].0)
                    before = await drive(client, maxCalls: 1)
                    try? await Task.sleep(for: .seconds(2))
                }
                let start = client.calls.count
                client.say(utterance)
                var names = await drive(client)
                names = Array(names)
                let firstCall = client.calls.count > start ? client.calls[start] : nil
                var first = firstCall?.name ?? "none"
                if first == "hand_off_to_agent", firstCall?.args["action"]?.stringValue == "cancel" { first += ":cancel" }
                row(["rep": .int(Int64(rep)), "utterance": .string(utterance), "expected": json(expected.sorted()), "before": json(before),
                     "first": .string(first), "calls": json(names), "correct": .bool(expected.contains(first))], client)
                client.shutdown()
            }
        }
        try write("q3-routing")
    }

    // MARK: Q4 Hand-off and briefing

    func briefing(_ client: LiveClient) {
        client.respond(id: "b-1", name: "briefing", [
            "kind": "researchAnswer", "status": "answered", "request": .string(Self.routing[3].0), "content": .string(Self.briefingAnswer),
            "message": "The Agent you handed off to has answered. Open straight with the answer: restate it in about two sentences in the user's language and say the sources are on screen; don't read it out."
        ], .whenIdle)
    }

    func testQ4HandOff() async throws {
        for (variant, delay) in [("briefing-30s", 30.0), ("briefing-90s", 90.0), ("briefing-mid-reply", 30.0), ("cancel", 0), ("cancel", 0)] {
            let (client, ok) = await session(voiceSet)
            guard ok else { row(["variant": .string(variant), "setupOK": false], client); continue }
            client.say(Self.routing[3].0)
            let handOff = await drive(client, maxCalls: 1)
            let t0 = client.now
            var fields: [String: JSONValue] = ["variant": .string(variant), "handOff": json(handOff)]
            if variant == "cancel" {
                try? await Task.sleep(for: .seconds(5))
                let count = client.calls.count
                client.say("Never mind, stop that.")
                let call = await client.nextCall(after: count)
                fields["cancelCall"] = .string(call.map { "\($0.name) \(json($0.args))" } ?? "none")
                fields["correct"] = .bool(call?.name == "hand_off_to_agent" && call?.args["action"]?.stringValue == "cancel")
                if let call { let (r, s) = canned(call); client.respond(call, r, s) }
                _ = await client.wait(10) { client.turnCompleteTimes.count >= 2 }
            } else {
                // The user keeps talking while the hand-off runs.
                try? await Task.sleep(for: .seconds(4))
                client.say("Next post.")
                let meanwhile1 = await drive(client, maxCalls: 2)
                client.say("What does post 20 say?")
                let meanwhile2 = await drive(client, maxCalls: 2)
                fields["meanwhile"] = json(meanwhile1 + meanwhile2)
                if variant == "briefing-mid-reply" {
                    _ = await client.wait(max(0, t0 + delay - client.now)) { false }
                    client.say("Tell me more about what carol said, in two or three sentences.")
                    let audioBefore = client.audioTimes.count
                    _ = await client.wait(20) { client.audioTimes.count > audioBefore + 3 }
                    fields["briefingWhileSpeaking"] = .bool(client.turnCompleteTimes.last.map { $0 < client.audioTimes.last ?? 0 } ?? true)
                } else {
                    _ = await client.wait(max(0, t0 + delay - client.now)) { false }
                }
                let spokenBefore = client.spoken.count
                let sent = client.now
                fields["briefingAfterSeconds"] = .double(sent - t0)
                briefing(client)
                let audioCount = client.audioTimes.count
                _ = await client.wait(30) { client.audioTimes.count > audioCount && client.turnCompleteTimes.last.map { $0 > sent } == true }
                let after = String(client.spoken.dropFirst(spokenBefore)).lowercased()
                fields["briefingSpoken"] = .string(after)
                fields["briefingFirstAudioSeconds"] = .double(client.audioTimes.first { $0 > sent }.map { $0 - sent } ?? -1)
                fields["correct"] = .bool(["proxmox", "16", "six watts", "6 watts", "sata"].contains { after.contains($0) })
            }
            row(fields, client)
            client.shutdown()
        }
        try write("q4-handoff")
    }

    // MARK: Q5 Direct dark mode

    /// Pass rule, fixed before running: the page background's luminance is at most 0.1, at least 95 %
    /// of visible text elements reach 4.5:1 against their effective background, and no block of
    /// 20,000 px² or more keeps a background lighter than luminance 0.4.
    static let passRule = "pageBg <= 0.1 && textPass >= 0.95 && brightBlocks == 0"

    func testQ5DarkMode() async throws {
        let web = DarkModePage()
        for (name, html) in DarkModeFixtures.pages {
            try await web.load(html)
            let structure = try await web.structure()
            let before = try await web.measure()
            row(["page": .string(name), "baseline": before], nil)
            for rep in 0..<3 {
                let (client, ok) = await session(voiceSet + [SpikeTools.declaration(SpikeTools.injectCSS)], instructions: SpikeTools.instructions(directCSS: true),
                                                 note: "[Screen: the user is on the page “\(name)”, an ordinary web page, not a forum.]")
                guard ok else { row(["page": .string(name), "setupOK": false], client); continue }
                var css: String?
                client.say("Switch to dark mode.")
                let calls = await drive(client) { call in
                    if call.name == "read_page" { return (["status": "read", "content": .string(structure)], .whenIdle) }
                    if call.name == "inject_css" { css = call.args["css"]?.stringValue }
                    return self.canned(call)
                }
                var result: JSONValue = .null
                var pass = false
                if let css {
                    try await web.load(html)
                    try await web.inject(css)
                    result = try await web.measure()
                    let o = result.objectValue ?? [:]
                    pass = (o["pageBg"]?.doubleValue ?? 1) <= 0.1 && (o["textPass"]?.doubleValue ?? 0) >= 0.95 && o["brightBlocks"]?.intValue == 0
                }
                row(["page": .string(name), "rep": .int(Int64(rep)), "calls": json(calls), "css": .string(css ?? ""), "after": result, "pass": .bool(pass)], client)
                client.shutdown()
            }
        }
        try write("q5-darkmode", ["passRule": .string(Self.passRule)])
    }

    // MARK: Q6 Result size

    func testQ6ResultSize() async throws {
        let filler = "Another reply in this thread says the fan ramps up after the update, and that the noise is worst at night when the room is quiet. "
        for rep in 0..<2 {
            for size in [1_000, 4_000, 16_000, 32_000, 64_000, 100_000] {
                let (client, ok) = await session(voiceSet)
                guard ok else { row(["chars": .int(Int64(size)), "setupOK": false], client); continue }
                client.say("Read post 20 for me and tell me what its very last sentence says.")
                guard let call = await client.nextCall(after: 0) else { row(["chars": .int(Int64(size)), "call": "none"], client); client.shutdown(); continue }
                let fact = " The very last sentence: the fix was to set the fan curve to profile number 47."
                let body = String(repeating: filler, count: max(1, (size - fact.count) / filler.count)) + fact
                let sent = client.now
                client.respond(call, ["status": "read", "shown": "Post 20 by carol", "content": .string(body), "message": "Answer the user from this text only."], .whenIdle)
                _ = await client.wait(45) { client.turnCompleteTimes.last.map { $0 > sent } == true || client.close != nil }
                _ = await client.wait(3) { client.usage != nil }
                let spoken = client.spoken.lowercased()
                row(["rep": .int(Int64(rep)), "chars": .int(Int64(body.count)), "call": .string(call.name),
                     "firstAudioSeconds": .double(client.audioTimes.first { $0 > sent }.map { $0 - sent } ?? -1),
                     "turnSeconds": .double(client.turnCompleteTimes.last { $0 > sent }.map { $0 - sent } ?? -1),
                     "promptTokens": .int(Int64(client.usage?.promptTokens ?? -1)),
                     "foundFact": .bool(spoken.contains("47") || spoken.contains("forty-seven") || spoken.contains("forty seven")),
                     "close": .string(client.close.map { "\($0.code ?? -1) \($0.reason)" } ?? "")], client)
                client.shutdown()
            }
        }
        try write("q6-result-size")
    }
}

extension JSONValue {
    var doubleValue: Double? {
        switch self { case .int(let v): Double(v); case .double(let v): v; default: nil }
    }
}
