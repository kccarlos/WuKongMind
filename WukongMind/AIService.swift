import Foundation

/// Not final so tests can stand in for the provider (streams, gated answers).
class AIService: @unchecked Sendable {
    private let session: URLSession
    /// The Apple Intelligence provider (FoundationModels); tests pass a fake.
    let appleIntelligence: AppleIntelligenceServing

    init(
        session: URLSession = .shared,
        appleIntelligence: AppleIntelligenceServing = AppleIntelligenceClient.shared
    ) {
        self.session = session
        self.appleIntelligence = appleIntelligence
    }

    func generateSummary(
        content: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        customPrompt: String,
        discussion: DiscussionProfile,
        batchLimit: Int = SummaryBatchLimit.default,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        if provider == .appleIntelligence {
            return try await appleIntelligenceSummary(
                content: content,
                configuration: configuration,
                customPrompt: customPrompt,
                discussion: discussion,
                onDelta: onDelta,
                onProgress: onProgress
            )
        }
        return try await hierarchicalSummary(
            content: content,
            configuration: configuration,
            provider: provider,
            customPrompt: customPrompt,
            discussion: discussion,
            batchLimit: SummaryBatchLimit.normalized(batchLimit),
            maxLevel: 4,
            onDelta: onDelta,
            onProgress: onProgress
        )
    }

    /// Summarizes in one request, or in batches of `batchLimit` characters
    /// whose summaries are folded (up to `maxLevel` levels) and combined.
    func hierarchicalSummary(
        content: String,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        customPrompt: String,
        discussion: DiscussionProfile,
        batchLimit: Int,
        maxLevel: Int,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
    ) async throws -> String {
        let chunks = PromptBuilder.splitForHierarchicalSummary(content, limit: batchLimit)
        if chunks.count == 1 {
            await onProgress(.finalStarted(combining: false))
            return try await streamText(
                system: PromptBuilder.summarySystem(custom: customPrompt, discussion: discussion),
                messages: [ChatMessage(role: .user, content: content)],
                configuration: configuration,
                provider: provider,
                onDelta: Self.counting(onDelta, onProgress: onProgress)
            )
        }

        // Summarize each batch, then keep folding the batch summaries until they
        // fit a single request; very long discussions need more than one level.
        var partials = try await summarizeBatches(
            chunks,
            level: 1,
            discussion: discussion,
            configuration: configuration,
            provider: provider,
            onDelta: onDelta,
            onProgress: onProgress
        )
        var level = 2
        // Bounded so a model that answers at length cannot fold indefinitely.
        while level <= maxLevel,
              partials.count > 1,
              partials.joined(separator: "\n\n---\n\n").count > batchLimit {
            let regrouped = PromptBuilder.splitForHierarchicalSummary(
                partials.joined(separator: "\n\n---\n\n"),
                limit: batchLimit
            )
            partials = try await summarizeBatches(
                regrouped,
                level: level,
                discussion: discussion,
                configuration: configuration,
                provider: provider,
                onDelta: onDelta,
                onProgress: onProgress
            )
            level += 1
        }

        let combining = String(localized: "Combining section summaries…", comment: "Shown in a long summary while the section summaries are merged")
        await onDelta("\n\n_\(combining)_\n")
        await onProgress(.finalStarted(combining: true))
        return try await streamText(
            system: PromptBuilder.summarySystem(custom: customPrompt, discussion: discussion),
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Create the final summary from these intermediate summaries:\n\n"
                        + partials.joined(separator: "\n\n---\n\n")
                )
            ],
            configuration: configuration,
            provider: provider,
            onDelta: Self.counting(onDelta, onProgress: onProgress)
        )
    }

    /// Passes deltas through and reports how many characters have arrived.
    private static func counting(
        _ onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void
    ) -> @MainActor (String) -> Void {
        let received = StreamedCharacters()
        return { delta in
            onDelta(delta)
            received.count += delta.count
            onProgress(.streamed(characters: received.count))
        }
    }

    private func summarizeBatches(
        _ chunks: [String],
        level: Int,
        discussion: DiscussionProfile,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void
    ) async throws -> [String] {
        await onProgress(.batchesPlanned(level: level, sizes: chunks.map(\.count)))
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let reading = level == 1
                ? String(localized: "Reading section \(index + 1) of \(chunks.count)…", comment: "Shown in a long summary while each section of the discussion is summarized")
                : String(localized: "Reading level \(level) section \(index + 1) of \(chunks.count)…", comment: "Shown in a very long summary while section summaries are condensed again; level is 2, 3, …")
            await onDelta("\n\n_\(reading)_\n")
            await onProgress(.batchStarted(level: level, index: index, count: chunks.count))
            let partial = try await streamText(
                system: PromptBuilder.chunkPrompt(discussion),
                messages: [ChatMessage(role: .user, content: chunk)],
                configuration: configuration,
                provider: provider,
                // Batch text is not shown; its length still moves the bar.
                onDelta: Self.counting({ _ in }, onProgress: onProgress)
            )
            partials.append(partial)
            await onProgress(.batchFinished(level: level, index: index, count: chunks.count))
        }
        return partials
    }

    func answer(
        source: String,
        summary: String,
        history: [ChatMessage],
        contextLimit: Int,
        customPrompt: String,
        discussion: DiscussionProfile,
        configuration: ProviderConfiguration,
        provider: AIProvider,
        onDelta: @escaping @MainActor (String) -> Void,
        summaryIsStale: Bool = false
    ) async throws -> String {
        if provider == .appleIntelligence {
            return try await appleIntelligenceAnswer(
                source: source,
                summary: summary,
                history: history,
                contextLimit: contextLimit,
                customPrompt: customPrompt,
                discussion: discussion,
                configuration: configuration,
                onDelta: onDelta,
                summaryIsStale: summaryIsStale
            )
        }
        let boundedSource = PromptBuilder.boundedForumContext(source, limit: contextLimit)
        return try await streamText(
            system: PromptBuilder.chatSystem(
                custom: customPrompt,
                source: boundedSource,
                summary: summary,
                discussion: discussion,
                summaryIsStale: summaryIsStale
            ),
            messages: Array(history.suffix(24)),
            configuration: configuration,
            provider: provider,
            maxTokens: 4_096,
            onDelta: onDelta
        )
    }

    /// One non-streamed completion; used by the agent planner.
    func complete(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int = 4_096
    ) async throws -> String {
        try await streamText(
            system: system,
            messages: messages,
            configuration: configuration,
            provider: provider,
            maxTokens: maxTokens,
            onDelta: { _ in }
        )
    }

    func discoverModels(
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> [String] {
        if provider == .appleIntelligence {
            // No model list: the system picks the backend.
            let backend = try appleIntelligence.requireBackend()
            return [backend.label]
        }
        if provider == .vertexAI {
            return AIProvider.vertexAIModels
        }
        let base = normalizedBaseURL(configuration.baseURL)
        var request: URLRequest

        switch provider {
        case .gemini:
            guard var components = URLComponents(string: "\(base)/models") else {
                throw AssistantError.invalidResponse
            }
            components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
            guard let url = components.url else { throw AssistantError.invalidResponse }
            request = URLRequest(url: url)
        case .ollama:
            guard let url = URL(string: "\(base)/api/tags") else {
                throw AssistantError.invalidResponse
            }
            request = URLRequest(url: url)
        default:
            guard let url = URL(string: "\(base)/models") else {
                throw AssistantError.invalidResponse
            }
            request = URLRequest(url: url)
            applyAuthentication(
                to: &request,
                configuration: configuration,
                provider: provider
            )
        }

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AssistantError.invalidResponse
        }

        let models: [String]
        if provider == .gemini {
            models = (json["models"] as? [[String: Any]] ?? [])
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        } else if provider == .ollama {
            models = (json["models"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
        } else {
            models = (json["data"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
        }
        return Array(Set(models)).sorted()
    }

    func testConnection(
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws {
        if provider.requiresAPIKey && configuration.apiKey.isEmpty {
            throw AssistantError.missingConfiguration(String(localized: "\(provider.displayName) API key is required.", comment: "Error; the placeholder is the AI provider's name"))
        }
        if provider == .vertexAI {
            // The model list is built in, so check the key against the model
            // itself; counting tokens is free and spends no generation quota.
            try validate(configuration: configuration, provider: provider)
            var request = URLRequest(url: try vertexAIURL(configuration: configuration, method: "countTokens"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [["role": "user", "parts": [["text": "Hello"]]]]
            ])
            applyAuthentication(to: &request, configuration: configuration, provider: provider)
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            return
        }
        let models = try await discoverModels(configuration: configuration, provider: provider)
        let chosen = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider != .appleIntelligence, !chosen.isEmpty, !models.isEmpty {
            let matches = models.contains(chosen)
                || (provider == .ollama && models.contains("\(chosen):latest"))
            if !matches {
                throw AssistantError.missingConfiguration(
                    String(
                        localized: "Model “\(chosen)” isn’t available from \(provider.displayName).",
                        comment: "Error when Test Connection finds the server reachable but the chosen model ID is not in its model list; arguments are model name and provider name"
                    )
                )
            }
        }
    }

    /// `{base}/publishers/google/models/{model}:{method}`; the base is the
    /// express-mode host or a project and location path.
    private func vertexAIURL(configuration: ProviderConfiguration, method: String) throws -> URL {
        let base = normalizedBaseURL(configuration.baseURL)
        let escapedModel = configuration.model.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? configuration.model
        guard let url = URL(string: "\(base)/publishers/google/models/\(escapedModel):\(method)")
        else {
            throw AssistantError.invalidResponse
        }
        return url
    }

    func streamText(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int = 16_384,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        if provider == .appleIntelligence {
            return try await appleIntelligenceText(
                system: system,
                messages: messages,
                maxTokens: maxTokens,
                onDelta: onDelta
            )
        }
        try validate(configuration: configuration, provider: provider)
        var tokenBudgets: [Int] = [
            maxTokens,
            min(maxTokens, 4_096),
            min(maxTokens, 2_048),
            min(maxTokens, 1_024)
        ]
        tokenBudgets = tokenBudgets.reduce(into: []) { budgets, value in
            if !budgets.contains(value) { budgets.append(value) }
        }
        var budgetIndex = 0

        while true {
            let requestedMaxTokens = tokenBudgets[budgetIndex]
            let request = try makeRequest(
                system: system,
                messages: messages,
                configuration: configuration,
                provider: provider,
                maxTokens: requestedMaxTokens
            )
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AssistantError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines {
                    body += line
                    if body.count > 1_000 { break }
                }
                let detail = body.isEmpty
                    ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    : String(body.prefix(1_000))
                let indicatesTokenBudget = detail.localizedCaseInsensitiveContains("max_tokens")
                    || detail.localizedCaseInsensitiveContains("max output")
                if http.statusCode == 402,
                   budgetIndex + 1 < tokenBudgets.count,
                   indicatesTokenBudget
                {
                    budgetIndex += 1
                    continue
                }
                throw AssistantError.http(http.statusCode, detail)
            }

            var result = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let delta = parseDelta(line: line, provider: provider), !delta.isEmpty else {
                    continue
                }
                result += delta
                await onDelta(delta)
            }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantError.emptyResponse
            }
            return result
        }
    }

    private static func coalesced(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            if let last = result.last, last.role == message.role {
                result[result.count - 1].content = last.content + "\n\n" + message.content
            } else {
                result.append(message)
            }
        }
        return result
    }

    private func makeRequest(
        system: String,
        messages: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int
    ) throws -> URLRequest {
        let messages = Self.coalesced(messages)
        let base = normalizedBaseURL(configuration.baseURL)
        let url: URL
        var body: [String: Any]

        switch provider {
        case .anthropic:
            guard let endpoint = URL(string: "\(base)/messages") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "max_tokens": maxTokens,
                "system": system,
                "stream": true,
                "messages": messages.map {
                    ["role": $0.role.rawValue, "content": $0.content]
                }
            ]

        case .gemini, .vertexAI:
            let escapedModel = configuration.model.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? configuration.model
            let path = provider == .vertexAI ? "publishers/google/models" : "models"
            guard var components = URLComponents(
                string: "\(base)/\(path)/\(escapedModel):streamGenerateContent"
            ) else {
                throw AssistantError.invalidResponse
            }
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            // Vertex AI takes the key in a header (see applyAuthentication).
            if provider == .gemini {
                components.queryItems?.append(URLQueryItem(name: "key", value: configuration.apiKey))
            }
            guard let endpoint = components.url else { throw AssistantError.invalidResponse }
            url = endpoint
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": messages.map {
                    [
                        "role": $0.role == .assistant ? "model" : "user",
                        "parts": [["text": $0.content]]
                    ]
                },
                "generationConfig": [
                    "temperature": 0.2,
                    "maxOutputTokens": maxTokens
                ]
            ]

        case .ollama:
            guard let endpoint = URL(string: "\(base)/api/chat") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "stream": true,
                "options": ["num_predict": maxTokens],
                "messages": [["role": "system", "content": system]]
                    + messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
            ]

        default:
            guard let endpoint = URL(string: "\(base)/chat/completions") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "temperature": 0.2,
                "stream": true,
                "max_tokens": maxTokens,
                "messages": [["role": "system", "content": system]]
                    + messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Some OpenAI-compatible hosts (NVIDIA NIM) buffer the whole reply
        // unless the client explicitly accepts server-sent events.
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthentication(
            to: &request,
            configuration: configuration,
            provider: provider
        )
        return request
    }

    private func validate(
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) throws {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AssistantError.missingConfiguration(String(localized: "Choose a model in Settings."))
        }
        guard URL(string: configuration.baseURL) != nil else {
            throw AssistantError.missingConfiguration(String(localized: "Enter a valid provider URL."))
        }
        if provider.requiresAPIKey && configuration.apiKey.isEmpty {
            throw AssistantError.missingConfiguration(
                String(localized: "\(provider.displayName) API key is required. Add it in Settings › AI models.", comment: "Error; the placeholder is the AI provider's name. Settings › AI models names the app's own Settings pages.")
            )
        }
    }

    private func applyAuthentication(
        to request: inout URLRequest,
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) {
        switch provider {
        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .vertexAI:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .gemini, .ollama, .lmStudio:
            break
        default:
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        if provider == .openRouter {
            request.setValue(
                "https://github.com/kccarlos/WuKongMind",
                forHTTPHeaderField: "HTTP-Referer"
            )
            request.setValue("WukongMind", forHTTPHeaderField: "X-Title")
        }
    }

    private func normalizedBaseURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private func parseDelta(line: String, provider: AIProvider) -> String? {
        var payload = line
        if payload.hasPrefix("data:") {
            payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        switch provider {
        case .anthropic:
            return ((json["delta"] as? [String: Any])?["text"] as? String)
        case .gemini, .vertexAI:
            let candidates = json["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined()
        case .ollama:
            return ((json["message"] as? [String: Any])?["content"] as? String)
        default:
            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AssistantError.http(http.statusCode, String(detail.prefix(500)))
        }
    }

    // MARK: - Native Tool Calling (Browser Agent)

    func completeToolTurn(
        system: String,
        messages: [AgentModelTurn],
        tools: [AgentToolDefinition],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int = 4_096
    ) async throws -> AgentModelTurnResponse {
        try Task.checkCancellation()
        guard provider.supportsToolCalling else {
            throw AssistantError.missingConfiguration(
                "\(provider.displayName) does not support browser agent tool calling. Choose a tool-calling model in Settings."
            )
        }
        try validate(configuration: configuration, provider: provider)

        let request = try makeToolRequest(
            system: system,
            messages: messages,
            tools: tools,
            configuration: configuration,
            provider: provider,
            maxTokens: maxTokens
        )
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validate(response: response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.invalidResponse
        }
        return try parseToolResponse(json: json, provider: provider)
    }

    func makeToolRequest(
        system: String,
        messages: [AgentModelTurn],
        tools: [AgentToolDefinition],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int
    ) throws -> URLRequest {
        let base = normalizedBaseURL(configuration.baseURL)
        let url: URL
        var body: [String: Any]

        switch provider {
        case .anthropic:
            guard let endpoint = URL(string: "\(base)/messages") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": Self.anthropicMessages(from: messages)
            ]
            if !tools.isEmpty {
                body["tools"] = tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "input_schema": JSONValue.object(tool.inputSchema).toFoundation()
                    ]
                }
            }

        case .gemini, .vertexAI:
            let escapedModel = configuration.model.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? configuration.model
            let path = provider == .vertexAI ? "publishers/google/models" : "models"
            guard var components = URLComponents(
                string: "\(base)/\(path)/\(escapedModel):generateContent"
            ) else {
                throw AssistantError.invalidResponse
            }
            if provider == .gemini {
                components.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
            }
            guard let endpoint = components.url else { throw AssistantError.invalidResponse }
            url = endpoint
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": Self.geminiContents(from: messages),
                "generationConfig": [
                    "temperature": 0.2,
                    "maxOutputTokens": maxTokens
                ]
            ]
            if !tools.isEmpty {
                body["tools"] = [
                    [
                        "functionDeclarations": tools.map { tool in
                            [
                                "name": tool.name,
                                "description": tool.description,
                                "parameters": Self.geminiParameters(from: tool.inputSchema)
                            ]
                        }
                    ]
                ]
            }

        case .ollama:
            guard let endpoint = URL(string: "\(base)/api/chat") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "stream": false,
                "options": ["num_predict": maxTokens],
                "messages": Self.openAIMessages(system: system, turns: messages, ollamaMode: true)
            ]
            if !tools.isEmpty {
                body["tools"] = Self.openAIToolDefinitions(from: tools)
            }

        default:
            guard let endpoint = URL(string: "\(base)/chat/completions") else {
                throw AssistantError.invalidResponse
            }
            url = endpoint
            body = [
                "model": configuration.model,
                "temperature": 0.2,
                "max_tokens": maxTokens,
                "messages": Self.openAIMessages(system: system, turns: messages, ollamaMode: false)
            ]
            if !tools.isEmpty {
                body["tools"] = Self.openAIToolDefinitions(from: tools)
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthentication(to: &request, configuration: configuration, provider: provider)
        return request
    }

    private static func anthropicMessages(from turns: [AgentModelTurn]) -> [[String: Any]] {
        var encoded: [(role: String, blocks: [[String: Any]])] = []

        func appendBlocks(role: String, _ newBlocks: [[String: Any]]) {
            guard !newBlocks.isEmpty else { return }
            if let last = encoded.last, last.role == role {
                encoded[encoded.count - 1].blocks.append(contentsOf: newBlocks)
            } else {
                encoded.append((role: role, blocks: newBlocks))
            }
        }

        for turn in turns {
            switch turn {
            case .user(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                appendBlocks(role: "user", [["type": "text", "text": text]])

            case .assistant(let text, let toolCalls):
                var blocks: [[String: Any]] = []
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": JSONValue.object(call.arguments).toFoundation()
                    ])
                }
                appendBlocks(role: "assistant", blocks)

            case .toolResults(let results):
                let blocks: [[String: Any]] = results.map { res in
                    [
                        "type": "tool_result",
                        "tool_use_id": res.toolCallID,
                        "content": res.content,
                        "is_error": res.isError
                    ]
                }
                appendBlocks(role: "user", blocks)
            }
        }

        return encoded.map { ["role": $0.role, "content": $0.blocks] }
    }

    private static func openAIToolDefinitions(from tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": JSONValue.object(tool.inputSchema).toFoundation()
                ]
            ]
        }
    }

    private static func openAIMessages(
        system: String,
        turns: [AgentModelTurn],
        ollamaMode: Bool
    ) -> [[String: Any]] {
        var result: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn {
            case .user(let text):
                result.append(["role": "user", "content": text])
            case .assistant(let text, let toolCalls):
                if toolCalls.isEmpty {
                    result.append(["role": "assistant", "content": text])
                } else {
                    let callsPayload: [[String: Any]] = toolCalls.map { call in
                        let argumentsField: Any = ollamaMode
                            ? JSONValue.object(call.arguments).toFoundation()
                            : (call.rawArgumentsJSON ?? JSONValue.encodeCompactJSON(call.arguments))
                        return [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": argumentsField
                            ]
                        ]
                    }
                    var msg: [String: Any] = [
                        "role": "assistant",
                        "tool_calls": callsPayload
                    ]
                    if ollamaMode {
                        msg["content"] = text
                    } else {
                        msg["content"] = text.isEmpty ? NSNull() : text
                    }
                    result.append(msg)
                }
            case .toolResults(let results):
                for res in results {
                    var msg: [String: Any] = [
                        "role": "tool",
                        "content": res.content
                    ]
                    if ollamaMode {
                        msg["tool_name"] = res.toolName
                    } else {
                        msg["tool_call_id"] = res.toolCallID
                    }
                    result.append(msg)
                }
            }
        }
        return result
    }

    private static func geminiParameters(from schema: [String: JSONValue]) -> Any {
        var copy = schema
        copy.removeValue(forKey: "additionalProperties")
        return JSONValue.object(copy).toFoundation()
    }

    private static func geminiContents(from turns: [AgentModelTurn]) -> [[String: Any]] {
        var contents: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                contents.append([
                    "role": "user",
                    "parts": [["text": text]]
                ])
            case .assistant(let text, let toolCalls):
                var parts: [[String: Any]] = []
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(["text": text])
                }
                for call in toolCalls {
                    var part: [String: Any] = [
                        "functionCall": [
                            "name": call.name,
                            "args": JSONValue.object(call.arguments).toFoundation()
                        ]
                    ]
                    if let signature = call.thoughtSignature {
                        part["thoughtSignature"] = signature
                    }
                    parts.append(part)
                }
                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": parts])
                }
            case .toolResults(let results):
                let parts: [[String: Any]] = results.map { res in
                    [
                        "functionResponse": [
                            "name": res.toolName,
                            "response": [
                                "result": res.content,
                                "is_error": res.isError
                            ]
                        ]
                    ]
                }
                if !parts.isEmpty {
                    contents.append(["role": "user", "parts": parts])
                }
            }
        }
        return contents
    }

    private func parseToolResponse(
        json: [String: Any],
        provider: AIProvider
    ) throws -> AgentModelTurnResponse {
        switch provider {
        case .anthropic:
            let blocks = (json["content"] as? [[String: Any]]) ?? []
            var textSegments: [String] = []
            var toolCalls: [AgentModelToolCall] = []
            for block in blocks {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        textSegments.append(text)
                    }
                case "tool_use":
                    let id = (block["id"] as? String) ?? UUID().uuidString
                    let name = (block["name"] as? String) ?? ""
                    let inputDict = (block["input"] as? [String: Any]) ?? [:]
                    let parsedArgs = (try? JSONValue.fromFoundation(inputDict).objectValue) ?? [:]
                    toolCalls.append(AgentModelToolCall(id: id, name: name, arguments: parsedArgs))
                default:
                    break
                }
            }
            let usageDict = json["usage"] as? [String: Any]
            let inputTokens = ((usageDict?["input_tokens"] as? Int) ?? 0)
                + ((usageDict?["cache_creation_input_tokens"] as? Int) ?? 0)
                + ((usageDict?["cache_read_input_tokens"] as? Int) ?? 0)
            let outputTokens = (usageDict?["output_tokens"] as? Int) ?? 0
            return AgentModelTurnResponse(
                text: textSegments.joined(separator: "\n"),
                toolCalls: toolCalls,
                stopReason: json["stop_reason"] as? String,
                usage: AgentTokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            )

        case .gemini, .vertexAI:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            let content = candidate?["content"] as? [String: Any]
            let parts = (content?["parts"] as? [[String: Any]]) ?? []
            var textSegments: [String] = []
            var toolCalls: [AgentModelToolCall] = []
            for (index, part) in parts.enumerated() {
                if (part["thought"] as? Bool) == true { continue }
                if let text = part["text"] as? String, !text.isEmpty {
                    textSegments.append(text)
                }
                if let fnCall = part["functionCall"] as? [String: Any] {
                    let name = (fnCall["name"] as? String) ?? ""
                    let callID = (fnCall["id"] as? String) ?? "gemini-call-\(index)-\(UUID().uuidString.prefix(8))"
                    let argsObj = (fnCall["args"] as? [String: Any]) ?? [:]
                    let parsedArgs = (try? JSONValue.fromFoundation(argsObj).objectValue) ?? [:]
                    let signature = part["thoughtSignature"] as? String
                    toolCalls.append(
                        AgentModelToolCall(
                            id: callID,
                            name: name,
                            arguments: parsedArgs,
                            thoughtSignature: signature
                        )
                    )
                }
            }
            let usageMeta = json["usageMetadata"] as? [String: Any]
            let inputTokens = (usageMeta?["promptTokenCount"] as? Int) ?? 0
            let outputTokens = (usageMeta?["candidatesTokenCount"] as? Int) ?? 0
            return AgentModelTurnResponse(
                text: textSegments.joined(),
                toolCalls: toolCalls,
                stopReason: candidate?["finishReason"] as? String,
                usage: AgentTokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            )

        case .ollama:
            let message = (json["message"] as? [String: Any]) ?? [:]
            let text = (message["content"] as? String) ?? ""
            let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
            let toolCalls = rawCalls.enumerated().map { index, rawCall -> AgentModelToolCall in
                let id = (rawCall["id"] as? String) ?? "ollama-call-\(index)"
                let fn = (rawCall["function"] as? [String: Any]) ?? [:]
                let name = (fn["name"] as? String) ?? ""
                if let argDict = fn["arguments"] as? [String: Any] {
                    let parsed = (try? JSONValue.fromFoundation(argDict).objectValue) ?? [:]
                    return AgentModelToolCall(id: id, name: name, arguments: parsed)
                } else if let argString = fn["arguments"] as? String {
                    if let parsed = try? JSONValue.parseObjectJSON(argString) {
                        return AgentModelToolCall(id: id, name: name, arguments: parsed)
                    }
                    return AgentModelToolCall(id: id, name: name, arguments: [:], rawArgumentsJSON: argString)
                }
                return AgentModelToolCall(id: id, name: name, arguments: [:])
            }
            let inputTokens = (json["prompt_eval_count"] as? Int) ?? 0
            let outputTokens = (json["eval_count"] as? Int) ?? 0
            return AgentModelTurnResponse(
                text: text,
                toolCalls: toolCalls,
                stopReason: json["done_reason"] as? String,
                usage: AgentTokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            )

        default:
            let choice = (json["choices"] as? [[String: Any]])?.first
            let message = (choice?["message"] as? [String: Any]) ?? [:]
            let text = (message["content"] as? String) ?? ""
            let rawCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
            let toolCalls = rawCalls.enumerated().map { index, rawCall -> AgentModelToolCall in
                let id = (rawCall["id"] as? String) ?? "call-\(index)"
                let fn = (rawCall["function"] as? [String: Any]) ?? [:]
                let name = (fn["name"] as? String) ?? ""
                if let argString = fn["arguments"] as? String {
                    if let parsed = try? JSONValue.parseObjectJSON(argString) {
                        return AgentModelToolCall(id: id, name: name, arguments: parsed)
                    }
                    return AgentModelToolCall(id: id, name: name, arguments: [:], rawArgumentsJSON: argString)
                } else if let argDict = fn["arguments"] as? [String: Any] {
                    let parsed = (try? JSONValue.fromFoundation(argDict).objectValue) ?? [:]
                    return AgentModelToolCall(id: id, name: name, arguments: parsed)
                }
                return AgentModelToolCall(id: id, name: name, arguments: [:])
            }
            let usageDict = json["usage"] as? [String: Any]
            let inputTokens = (usageDict?["prompt_tokens"] as? Int) ?? 0
            let outputTokens = (usageDict?["completion_tokens"] as? Int) ?? 0
            return AgentModelTurnResponse(
                text: text,
                toolCalls: toolCalls,
                stopReason: choice?["finish_reason"] as? String,
                usage: AgentTokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            )
        }
    }
}

/// Characters a summary request has streamed so far (only touched by the
/// main-actor delta closure).
private final class StreamedCharacters: @unchecked Sendable {
    var count = 0
}

extension AIService: AgentModelClient {}
