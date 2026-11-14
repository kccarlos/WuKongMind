import Foundation

// The network tools: `http_request` and `cookies_get` (design-m3.md, `http_request`,
// `cookies_get`, Confirmations).

extension ToolRegistry {
    static let declinedMessage = "The user declined this action."
    static let maxCookiesReturned = 200

    static func networkTools(context: AgentToolContext) -> [AgentTool] {
        guard let client = context.network else { return [] }
        return [
            makeHTTPRequestTool(context: context, client: client),
            makeCookiesGetTool(context: context, client: client)
        ]
    }

    // MARK: Confirmation

    /// What a request needs before it runs. The model's own `Cookie` header counts as `send_cookies`.
    struct HTTPRequestConfirmation: Equatable {
        enum Reason: Equatable { case crossSiteCookies, write }
        var reason: Reason
        var question: String
    }

    static func confirmationFor(
        request: AgentHTTPRequest,
        pageURL: URL?,
        confirmBeforeWrites: Bool
    ) -> HTTPRequestConfirmation? {
        let ownCookie = request.headers.keys.contains { $0.lowercased() == "cookie" }
        let usesCookies = request.sendCookies || ownCookie
        let host = request.url.host ?? request.url.absoluteString
        if usesCookies, !AgentSite.sameSite(request.url, pageURL) {
            return HTTPRequestConfirmation(
                reason: .crossSiteCookies,
                question: String(localized: "Send a request to \(host) using your login there?",
                                 comment: "Confirmation card: the Agent wants to call another site with the person's cookies. The placeholder is a host name")
            )
        }
        guard confirmBeforeWrites else { return nil }
        let target = host + (request.url.path == "/" ? "" : request.url.path)
        return HTTPRequestConfirmation(
            reason: .write,
            question: String(localized: "Send a \(request.method.uppercased()) request to \(target)?",
                             comment: "Confirmation card: the Agent wants to send an HTTP request. First placeholder is the method, second is host and path")
        )
    }

    // MARK: http_request

    private static func makeHTTPRequestTool(context: AgentToolContext, client: AgentHTTPClient) -> AgentTool {
        let workspace = context.workspace
        let secrets = context.settings.redactedSecrets
        let gate = context.confirmations
        var parameters = [
            ToolParameterSchema(name: "url", type: .string, description: "The http or https URL.", minLength: 1),
            ToolParameterSchema(
                name: "method", type: .string,
                description: "HTTP method (default GET).",
                enumValues: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
            ),
            ToolParameterSchema(name: "headers", type: .object, description: "Request headers, an object of strings."),
            ToolParameterSchema(name: "body", type: .string, description: "Request body text."),
            ToolParameterSchema(
                name: "send_cookies", type: .boolean,
                description: "Send the target site's cookies from the browser (default false). Another site than the current page asks the person first."
            ),
            ToolParameterSchema(
                name: "timeout", type: .integer, description: "Seconds, 1 to 120 (default 30).",
                minimum: 1, maximum: 120
            )
        ]
        if workspace != nil { parameters.append(saveToParameter) }
        return AgentTool(
            definition: AgentToolDefinition(
                name: "http_request",
                description: """
                Send an HTTP request from the app, outside the page, so the page's cross-origin rules \
                don't apply. Returns {status, url, headers, body}. Set-Cookie is never returned or stored. \
                Downloads stop at 20 MB.
                """,
                parameters: parameters,
                required: ["url"]
            ),
            summarizeArguments: { args in
                "\((args["method"]?.stringValue ?? "GET").uppercased()) \(args["url"]?.stringValue ?? "")"
            },
            execute: { args in
                let request = try parseHTTPRequest(args)
                let page = await client.environment.currentPageURL()
                let confirmWrites = await client.environment.confirmBeforeWrites()
                if let needed = confirmationFor(
                    request: request, pageURL: page, confirmBeforeWrites: confirmWrites
                ) {
                    let allowed = try await gate?.ask(
                        tool: "http_request", question: needed.question, detail: request.url.absoluteString
                    ) ?? false
                    guard allowed else { throw AgentHTTPError(message: declinedMessage) }
                }
                let response = try await client.send(request)
                return try await httpOutput(
                    response, request: request, workspace: workspace,
                    saveTo: args["save_to"]?.stringValue, secrets: secrets
                )
            }
        )
    }

    static func parseHTTPRequest(_ args: [String: JSONValue]) throws -> AgentHTTPRequest {
        guard let raw = args["url"]?.stringValue,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else {
            throw AgentHTTPError(message: "url must be an absolute http or https URL.")
        }
        var headers: [String: String] = [:]
        if let object = args["headers"]?.objectValue {
            for (name, value) in object {
                guard let text = value.stringValue else {
                    throw AgentHTTPError(message: "Header '\(name)' must be a string.")
                }
                headers[name] = text
            }
        }
        var request = AgentHTTPRequest(url: url)
        request.method = (args["method"]?.stringValue ?? "GET").uppercased()
        request.headers = headers
        request.body = args["body"]?.stringValue
        if case .bool(let send)? = args["send_cookies"] { request.sendCookies = send }
        if let timeout = args["timeout"]?.strictIntValue { request.timeout = TimeInterval(min(120, max(1, timeout))) }
        return request
    }

    private static func httpOutput(
        _ response: AgentHTTPResponse,
        request: AgentHTTPRequest,
        workspace: AgentWorkspace?,
        saveTo: String?,
        secrets: [String]
    ) async throws -> ToolExecutionOutput {
        var head: [String: Any] = [
            "status": response.status,
            "url": response.finalURL.absoluteString,
            "headers": response.headers
        ]
        if response.truncated { head["truncated"] = "The download stopped at 20 MB." }
        let summary = "\(response.status) · \(response.data.count) bytes"

        guard let text = response.text else {
            let kind = response.contentType ?? "unknown type"
            head["body"] = "binary, \(response.data.count) bytes, \(kind)"
            if saveTo != nil { head["note"] = "Not saved: the workspace holds text files only." }
            return ToolExecutionOutput(content: encode(head), summary: summary)
        }
        if let workspace, let target = saveTo {
            let saved = try await saveOutput(text, to: target, workspace: workspace, secrets: secrets)
            head["body_saved_to"] = saved.path
            return ToolExecutionOutput(
                content: encode(head) + "\n" + saved.notice,
                summary: "\(summary) · \(saved.path)",
                savedPath: saved.path
            )
        }
        head["body"] = text
        return ToolExecutionOutput(content: encode(head), summary: summary)
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: cookies_get

    private static func makeCookiesGetTool(context: AgentToolContext, client: AgentHTTPClient) -> AgentTool {
        let gate = context.confirmations
        return AgentTool(
            definition: AgentToolDefinition(
                name: "cookies_get",
                description: """
                Read the browser's cookies (httpOnly included) for a domain and its parent domains. \
                Always asks the person first.
                """,
                parameters: [
                    ToolParameterSchema(name: "domain", type: .string, description: "For example 'example.org'.", minLength: 1),
                    ToolParameterSchema(name: "name", type: .string, description: "Only the cookie with this name.", minLength: 1)
                ],
                required: ["domain"]
            ),
            summarizeArguments: { args in
                [args["domain"]?.stringValue, args["name"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
            },
            execute: { args in
                let domain = (args["domain"]?.stringValue ?? "").lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". /"))
                guard !domain.isEmpty else { throw AgentHTTPError(message: "domain is required.") }
                let name = args["name"]?.stringValue
                let matching = await client.environment.cookies().filter {
                    AgentCookies.domainMatches(cookieDomain: $0.domain, host: domain)
                        && (name == nil || $0.name == name)
                }
                let count = matching.count
                let question = String(
                    localized: "Read \(count) cookies for \(domain)?",
                    comment: "Confirmation card: the Agent wants to read cookies. First placeholder is the count, second the domain"
                )
                let allowed = try await gate?.ask(tool: "cookies_get", question: question, detail: domain) ?? false
                guard allowed else { throw AgentHTTPError(message: declinedMessage) }
                return cookiesOutput(matching)
            }
        )
    }

    static func cookiesOutput(_ cookies: [HTTPCookie]) -> ToolExecutionOutput {
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = cookies.prefix(maxCookiesReturned).map { cookie in
            var row: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "http_only": cookie.isHTTPOnly,
                "secure": cookie.isSecure,
                "expires": cookie.expiresDate.map(formatter.string(from:)) ?? NSNull()
            ]
            switch cookie.sameSitePolicy {
            case .sameSiteLax?: row["same_site"] = "lax"
            case .sameSiteStrict?: row["same_site"] = "strict"
            default: row["same_site"] = NSNull()
            }
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
        var content = String(decoding: data, as: UTF8.self)
        if cookies.count > maxCookiesReturned {
            content += "\n\(cookies.count - maxCookiesReturned) more cookies not shown (limit \(maxCookiesReturned))."
        }
        return ToolExecutionOutput(content: content, summary: "\(min(cookies.count, maxCookiesReturned)) cookies")
    }
}
