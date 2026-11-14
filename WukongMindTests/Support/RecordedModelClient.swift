import Foundation
#if canImport(WukongMind)
@testable import WukongMind
#endif

/// Returns scripted model responses in order and records each request (moved from `AgentLoopTests`).
final class RecordedModelClient: AgentModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedResponses: [Result<AgentModelTurnResponse, Error>]
    private(set) var recordedRequests: [(system: String, messages: [AgentModelTurn], tools: [AgentToolDefinition])] = []
    var onRequest: (@Sendable (Int) async throws -> Void)?

    init(_ responses: [Result<AgentModelTurnResponse, Error>]) {
        self.scriptedResponses = responses
    }

    func append(_ response: Result<AgentModelTurnResponse, Error>) {
        lock.lock()
        scriptedResponses.append(response)
        lock.unlock()
    }

    func completeToolTurn(
        system: String,
        messages: [AgentModelTurn],
        tools: [AgentToolDefinition],
        configuration: ProviderConfiguration,
        provider: AIProvider,
        maxTokens: Int
    ) async throws -> AgentModelTurnResponse {
        let (callNumber, next): (Int, Result<AgentModelTurnResponse, Error>) = lock.withLock {
            recordedRequests.append((system: system, messages: messages, tools: tools))
            let count = recordedRequests.count
            let item: Result<AgentModelTurnResponse, Error>
            if scriptedResponses.isEmpty {
                item = .success(AgentModelTurnResponse(text: "Default fallback reply."))
            } else {
                item = scriptedResponses.removeFirst()
            }
            return (count, item)
        }

        if let onRequest {
            try await onRequest(callNumber)
        }
        return try next.get()
    }

    /// Replays an exported task's responses, in order.
    convenience init(export document: TaskExportDocument) {
        self.init(document.turns.compactMap(\.response).map { .success($0) })
    }
}
