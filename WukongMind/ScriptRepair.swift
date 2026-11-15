import Foundation

struct ScriptRepairTarget: Codable, Equatable, Sendable {
    var scriptID: String
    var preRepairVersion: Int
    var preRepairIsEnabled: Bool
}

struct ScriptRepairRequest: Equatable, Sendable {
    var prompt: String
    var attachedBlock: String
    var target: ScriptRepairTarget
}

enum ScriptRepair {
    static let maxInlineSourceCharacters = 20_000
    static let maxErrorsIncluded = 5
    static let maxErrorMessageCharacters = 1_000
    static let toolTag = "script_repair"

    @MainActor
    static func request(
        for script: UserScript, in store: ScriptStore, currentPageURL: URL?, secrets: [String] = []
    ) -> ScriptRepairRequest {
        var recent = store.errors(for: script.id)
        if recent.isEmpty, let single = store.error(for: script.id) { recent = [single] }
        return request(for: script, errors: recent, currentPageURL: currentPageURL, secrets: secrets)
    }

    static func request(
        for script: UserScript, errors: [ScriptRuntimeError] = [], currentPageURL: URL? = nil, secrets: [String] = []
    ) -> ScriptRepairRequest {
        let prompt = String(
            localized: "Fix this script",
            comment: "Prompt sent to the model when tapping Let the Agent fix it on a broken script"
        )
        let target = ScriptRepairTarget(
            scriptID: script.id, preRepairVersion: script.version, preRepairIsEnabled: script.isEnabled
        )
        let originLabel = switch script.source { case .agent: "agent"; case .imported: "imported" }
        let matchesCurrentPage = currentPageURL.map { script.matches(url: $0) } ?? false
        let boundedErrors = Array(errors.prefix(maxErrorsIncluded))
        let lastErrorURL = boundedErrors.compactMap { err -> String? in
            let u = err.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return u.isEmpty ? nil : u
        }.first
        let wrap = { (text: String) in UntrustedWebContent.wrap(text, toolName: toolTag, secrets: secrets) }

        var lines: [String] = [
            "Script repair context (from WukongMind):",
            "- Script ID: \(script.id)",
            "- Revision: \(script.version)",
            "- Origin: \(originLabel)",
            "- Enabled: \(script.isEnabled ? "on" : "off")",
            "- Current page matches script: \(matchesCurrentPage ? "yes" : "no")",
            "- Grants: \(script.metadata.grants.isEmpty ? "none" : script.metadata.grants.joined(separator: ", "))"
        ]
        if !script.metadata.connectHosts.isEmpty {
            lines.append("- Connect hosts: \(script.metadata.connectHosts.joined(separator: ", "))")
        }
        lines += [
            "Script name:", wrap(script.name),
            "Match rules:", wrap(script.matchRules.isEmpty ? "(none)" : script.matchRules.joined(separator: "\n"))
        ]
        if let reason = script.disabledReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines += ["Saved disabled reason:", wrap(reason)]
        }
        if let lastErrorURL {
            lines += ["Last error page URL:", wrap(lastErrorURL)]
        } else {
            lines.append("- Last error page URL: unknown")
        }

        if boundedErrors.isEmpty {
            lines.append("Recent errors: none recorded in memory.")
        } else {
            let iso = ISO8601DateFormatter()
            lines.append("Recent errors (\(boundedErrors.count) of last \(maxErrorsIncluded)):")
            for (idx, err) in boundedErrors.enumerated() {
                let lineDesc = err.line.map(String.init) ?? "unknown"
                let phase = err.afterLoad ? "after load" : "during load"
                lines.append("Error #\(idx + 1) — kind: \(err.kind.rawValue), line: \(lineDesc), phase: \(phase), time: \(iso.string(from: err.occurredAt)), count: \(err.count)")
                if let url = err.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                    lines += ["Error #\(idx + 1) page URL:", wrap(url)]
                }
                let msg = err.message.count > maxErrorMessageCharacters
                    ? String(err.message.prefix(maxErrorMessageCharacters)) + "…"
                    : err.message
                lines += ["Error #\(idx + 1) message:", wrap(msg)]
                if let stack = ScriptRuntimeError.clampStack(err.stack) {
                    lines += ["Error #\(idx + 1) stack:", wrap(stack)]
                } else {
                    lines.append("Error #\(idx + 1) stack: none")
                }
            }
        }

        var sourceSections: [String] = []
        if !script.js.isEmpty { sourceSections.append(script.js) }
        if !script.css.isEmpty { sourceSections.append("/* CSS */\n\(script.css)") }
        let source = sourceSections.isEmpty ? "(empty)" : sourceSections.joined(separator: "\n\n")
        if source.count <= maxInlineSourceCharacters {
            lines += ["Script source (\(source.count) characters):", wrap(source)]
        } else {
            lines.append("Script source: \(source.count) characters (exceeds \(maxInlineSourceCharacters)); read it with `script_read`.")
        }
        return ScriptRepairRequest(prompt: prompt, attachedBlock: lines.joined(separator: "\n"), target: target)
    }
}
