import XCTest

// Baseline: how long "open bbc.com" takes through the hand-off today, the thing open_page replaces.
// Voice side: real Gemini Live, time from the user's sentence to the hand_off call (today's set).
// Agent side: claude-haiku-5-5 (Anthropic Messages API) with a stub toolset (navigate, read_page,
// inject_css, notify) and a short Agent-style system prompt, stubbed tool results, timed end to end.
// This is a LOWER BOUND for the real Agent (which has a longer prompt and ~30 tools and loads a
// real page), not the Agent itself.

extension VoiceSpikeTests {
    static var anthropicKey: String { ProcessInfo.processInfo.environment["SPIKE_ANTHROPIC_KEY"] ?? "" }

    func anthropic(_ body: [String: Any]) async throws -> ([String: Any], Double) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(Self.anthropicKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let start = Date()
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (object, Date().timeIntervalSince(start))
    }

    func testAWAgentBaseline() async throws {
        try XCTSkipIf(Self.anthropicKey.isEmpty, "SPIKE_ANTHROPIC_KEY is not set")
        let tools: [[String: Any]] = [
            ["name": "navigate", "description": "Open a full web address in the current tab.",
             "input_schema": ["type": "object", "properties": ["url": ["type": "string", "description": "A full address."]], "required": ["url"]]],
            ["name": "read_page", "description": "Read the current page as a structure list.",
             "input_schema": ["type": "object", "properties": ["mode": ["type": "string", "enum": ["structure", "text", "html"]]]]],
            ["name": "inject_css", "description": "Inject CSS rules on the current page.",
             "input_schema": ["type": "object", "properties": ["css": ["type": "string"]], "required": ["css"]]],
            ["name": "notify", "description": "Notify the user later.",
             "input_schema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]]
        ]
        let system = "You are WukongMind's browser Agent. You act on the page the user has open. Use tools, look before you change anything, and answer briefly."
        for rep in 0..<3 {
            // Voice side: the time to the hand-off call, with today's ordinary-page set and instruction.
            let (client, ok) = await session(AnywhereTools.todayOrdinary.map { SpikeTools.declaration($0) },
                                             instructions: AnywhereTools.todayOrdinaryInstructions, note: AnywhereTools.ordinaryNote)
            var voiceSeconds = -1.0, first = "none"
            if ok {
                let sent = client.now
                client.say("Open bbc.com.")
                let call = await client.nextCall(after: 0, timeout: 25)
                first = call?.name ?? "none"
                if let call { voiceSeconds = client.events.first { $0.kind == "call" }.map { $0.t - sent } ?? -1; client.respond(call, canned(call).0, canned(call).1) }
            }
            row(["part": "voice-to-handoff", "rep": .int(Int64(rep)), "first": .string(first), "seconds": .double((voiceSeconds * 100).rounded() / 100)], client)
            client.shutdown()

            // Agent side.
            var messages: [[String: Any]] = [["role": "user", "content": "Open bbc.com."]]
            var total = 0.0, steps = 0, called: [String] = [], finalText = ""
            for _ in 0..<5 {
                let (reply, dt) = try await anthropic(["model": "claude-haiku-5-5", "max_tokens": 400, "system": system, "tools": tools, "messages": messages])
                total += dt
                steps += 1
                let content = (reply["content"] as? [[String: Any]]) ?? []
                messages.append(["role": "assistant", "content": content])
                let uses = content.filter { $0["type"] as? String == "tool_use" }
                if uses.isEmpty { finalText = content.compactMap { $0["text"] as? String }.joined(); break }
                var results: [[String: Any]] = []
                for use in uses {
                    let name = use["name"] as? String ?? ""
                    called.append(name)
                    let text = name == "navigate" ? "Loaded https://www.bbc.com/ (title: BBC Home - Breaking News)" : "Page: BBC Home. Headlines: ..."
                    results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "", "content": text])
                }
                messages.append(["role": "user", "content": results])
            }
            row(["part": "agent-haiku-stub", "model": "claude-haiku-5-5", "rep": .int(Int64(rep)), "steps": .int(Int64(steps)), "tools": json(called),
                 "seconds": .double((total * 100).rounded() / 100), "final": .string(finalText)], nil)
        }
        try write("anywhere-agent-baseline")
    }
}
