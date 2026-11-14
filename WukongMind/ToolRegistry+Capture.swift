import Foundation

// MARK: - screenshot and network_log (design-m3.md, "Tools")

extension ToolRegistry {
    static func captureTools(context: AgentToolContext) -> [AgentTool] {
        var tools: [AgentTool] = []
        if context.settings.supportsImageInput {
            tools.append(makeScreenshotTool(bridge: context.bridge))
        }
        tools.append(makeNetworkLogTool(bridge: context.bridge))
        return tools
    }

    static func makeScreenshotTool(bridge: AgentPageDriving) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "screenshot",
                description: """
                Capture a JPEG screenshot of the current page to inspect visual layout, styling, \
                images, or rendered state. Defaults to 'visible'; pass area='full_page' for up to 8 screen heights.
                """,
                parameters: [
                    ToolParameterSchema(
                        name: "area",
                        type: .string,
                        description: "Portion of the page to capture: 'visible' (default) or 'full_page' (capped at 8 screen heights).",
                        enumValues: ScreenshotArea.allCases.map(\.rawValue)
                    )
                ],
                required: []
            ),
            summarizeArguments: { args in
                args["area"]?.stringValue == ScreenshotArea.fullPage.rawValue ? ScreenshotArea.fullPage.rawValue : ""
            },
            execute: { args in
                let area = ScreenshotArea(rawValue: args["area"]?.stringValue ?? "") ?? .visible
                let shot = try await bridge.screenshot(area: area)
                let urlDisplay = shot.url.isEmpty ? "(no page loaded)" : shot.url
                let areaLabel = shot.area == .fullPage ? "full page" : "visible"
                let dimensions = "\(shot.widthPt)×\(shot.heightPt) pt"
                var textLine = "Screenshot of \(urlDisplay), \(dimensions), \(areaLabel)"
                if shot.wasCapped {
                    textLine += " (capped at \(AgentBridge.maxFullPageScreens) screen heights)"
                }
                return ToolExecutionOutput(content: textLine, summary: dimensions, images: [shot.image])
            }
        )
    }

    static func makeNetworkLogTool(bridge: AgentPageDriving) -> AgentTool {
        AgentTool(
            definition: AgentToolDefinition(
                name: "network_log",
                description: """
                Read recent fetch and XMLHttpRequest traffic captured in the current page, newest first, \
                as JSON lines (up to 200 entries per page load). Request headers and Set-Cookie are never recorded.
                """,
                parameters: [
                    ToolParameterSchema(
                        name: "url_filter",
                        type: .string,
                        description: "Optional case-insensitive substring matched against each request URL."
                    ),
                    ToolParameterSchema(
                        name: "limit",
                        type: .integer,
                        description: "Maximum number of newest entries to return (1–200, default 50).",
                        minimum: 1,
                        maximum: Double(AgentPageCapture.maxBufferEntries)
                    ),
                    ToolParameterSchema(
                        name: "include_bodies",
                        type: .boolean,
                        description: "Include the first 2,000 characters of text and JSON responses as response_preview (default false)."
                    )
                ],
                required: []
            ),
            summarizeArguments: { args in
                if let filter = args["url_filter"]?.stringValue, !filter.isEmpty {
                    return condenseInline(filter, maxChars: 48)
                }
                return ""
            },
            execute: { args in
                let urlFilter = args["url_filter"]?.stringValue
                let limit = args["limit"]?.strictIntValue ?? AgentPageCapture.defaultNetworkLimit
                let includeBodies = args["include_bodies"]?.strictBoolValue ?? false
                let entries = try await bridge.networkLog(urlFilter: urlFilter, limit: limit, includeBodies: includeBodies)
                let content = entries.map { $0.jsonLine(includeBody: includeBodies) }.joined(separator: "\n")
                return ToolExecutionOutput(content: content, summary: "\(entries.count)")
            }
        )
    }
}
