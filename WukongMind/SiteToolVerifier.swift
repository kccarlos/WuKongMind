import Foundation

enum SiteVerificationStepStatus: String, Codable, Equatable, Sendable {
    case passed, failed, skipped
}

struct SiteVerificationStepResult: Codable, Equatable, Sendable {
    var step: Int, name: String, status: SiteVerificationStepStatus, detail: String? = nil
}

struct SiteSlotVerification: Equatable, Sendable {
    var slot: SiteToolSlot, primaryURL: String, testURLs: [String], counts: [Int]
    var postStarts: [String: [String]] = [:], durationMs: Double, searchQuery: String? = nil

    var summary: String {
        switch slot {
        case .readTopic:
            if counts.count >= 2 { return "verified on 2 threads: \(counts[0]) and \(counts[1]) posts" }
            let c = counts.first ?? 0
            return "verified on 1 thread: \(c) \(c == 1 ? "post" : "posts")"
        case .listLatest:
            let c = counts.first ?? 0
            return "verified on the list page: \(c) \(c == 1 ? "thread" : "threads")"
        case .searchForum:
            let c = counts.first ?? 0
            return "verified with a search for '\(searchQuery ?? "")': \(c) \(c == 1 ? "result" : "results")"
        }
    }
}

struct SiteToolVerificationReport: Equatable, Sendable {
    var passed: Bool, failedStep: Int? = nil, failedSlot: SiteToolSlot? = nil
    var failureCode: SiteFailureCode? = nil, reason: String? = nil
    var steps: [SiteVerificationStepResult] = []
    var slots: [SiteToolSlot: SiteSlotVerification] = [:]
    var headerTestURLs: [String] = [], verificationSummary: String = ""
}

struct SiteVerifierError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum SiteToolVerifier {
    struct Limits: Equatable, Sendable {
        var callTimeout: TimeInterval = PageToolBridge.defaultTimeout
        var maxResponseBytes: Int = PageToolBridge.defaultMaxResponseBytes
        static let `default` = Limits()
    }

    private static let stepNames: [Int: String] = [
        1: "Registered", 2: "Real arguments", 3: "Strict shape", 4: "Thread sanity",
        5: "List sanity", 6: "Not constant", 7: "Faithful", 8: "Bounded", 9: "Stays home"
    ]
    private static let htmlMarkupPattern = try! NSRegularExpression(
        pattern: #"(?i)</(p|div|span|article|section|blockquote|li|ul|ol|table|tr|td|h[1-6]|a|html|body)>|<br\s*/?>|<!doctype\s+html"#
    )
    private static let outerHTMLTagPattern = try! NSRegularExpression(pattern: #"(?is)^<([a-z][a-z0-9]*)\b[^>]*>.*</\1>$"#)
    private static let literalURLHostPattern = try! NSRegularExpression(
        pattern: "(?i)https?://(?:[^/\\s\"'`?#\\\\@]+@)?(\\[[0-9a-f:]+\\]|[a-z0-9.-]+)"
    )
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "what", "when", "where", "which",
        "have", "has", "had", "are", "was", "were", "not", "but", "you", "your", "into", "about",
        "thread", "threads", "forum", "forums", "post", "posts", "page", "topic", "topics", "discussion"
    ]

    static func scriptTextHash(for script: UserScript) -> String { ScriptStore.sha256Hex(Data(script.js.utf8)) }
    static func foldWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func postStart(_ body: String, maxCharacters: Int = 40) -> String { String(foldWhitespace(body).prefix(maxCharacters)) }

    static func containsHTMLMarkup(_ body: String) -> Bool {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains("<"), t.contains(">") else { return false }
        let r = NSRange(t.startIndex..<t.endIndex, in: t)
        return htmlMarkupPattern.firstMatch(in: t, range: r) != nil || outerHTMLTagPattern.firstMatch(in: t, range: r) != nil
    }

    static func singleNormalizedHost(for matchRules: [String]) -> Result<String, SiteVerifierError> {
        guard !matchRules.isEmpty else { return .failure(.init("match_rules must not be empty.")) }
        var resolved: String?
        for rule in matchRules {
            guard let p = try? MatchPattern.parse(rule) else { return .failure(.init("invalid match pattern '\(rule)'.")) }
            guard !p.isAllURLs, p.allowedSchemes.isSubset(of: ["http", "https"]),
                  case .exact(let raw) = p.hostRule, let norm = SiteToolState.normalizedHost(raw) else {
                return .failure(.init("a reading tool's match_rules must cover one http(s) host only (got '\(rule)')."))
            }
            if let existing = resolved, existing != norm {
                return .failure(.init("a reading tool's match_rules must cover one host only ('\(existing)' vs '\(norm)')."))
            }
            resolved = norm
        }
        return resolved.map(Result.success) ?? .failure(.init("match_rules must cover one host."))
    }

    static func validateSubMatchPatterns(_ patterns: [String], label: String, siteHost: String) -> Result<[MatchPattern], SiteVerifierError> {
        var parsed: [MatchPattern] = []
        for raw in patterns {
            guard let p = try? MatchPattern.parse(raw) else { return .failure(.init("invalid \(label) pattern '\(raw)'.")) }
            guard !p.isAllURLs, p.allowedSchemes.isSubset(of: ["http", "https"]),
                  case .exact(let h) = p.hostRule, SiteToolState.normalizedHost(h) == siteHost else {
                return .failure(.init("\(label) '\(raw)' must cover host '\(siteHost)' only."))
            }
            parsed.append(p)
        }
        return .success(parsed)
    }

    static func firstExternalHost(in source: String, siteHost: String) -> String? {
        guard let expected = SiteToolState.normalizedHost(siteHost) else { return nil }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in literalURLHostPattern.matches(in: source, range: nsRange) {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let rawHost = String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !rawHost.isEmpty else { continue }
            let normalized = SiteToolState.normalizedHost(rawHost) ?? rawHost.lowercased()
            if normalized != expected { return normalized }
        }
        return nil
    }

    static func pickSearchWord(from titles: [String]) -> String? {
        var fallback: String?
        for title in titles {
            for token in title.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init) where !token.isEmpty {
                let lower = token.lowercased()
                guard !stopWords.contains(lower), !token.allSatisfy(\.isNumber) else { continue }
                if (lower.unicodeScalars.contains { $0.value >= 0x80 } && lower.count >= 2) || lower.count >= 3 { return lower }
                if fallback == nil, lower.count >= 2 { fallback = lower }
            }
        }
        return fallback
    }

    static func verify(
        candidate: UserScript, providedSlots: [SiteToolSlot], siteHost: String, openPageURL: String,
        rawTestURLs: [String], existingState: SiteToolState?, bridge: AgentPageDriving,
        pageToolBridge: PageToolBridge, scriptStore: ScriptStore, limits: Limits = .default
    ) async -> SiteToolVerificationReport {
        var steps: [SiteVerificationStepResult] = []
        func fail(_ step: Int, slot: SiteToolSlot?, code: SiteFailureCode, _ reason: String) -> SiteToolVerificationReport {
            steps.append(.init(step: step, name: stepNames[step] ?? "Step \(step)", status: .failed, detail: reason))
            return SiteToolVerificationReport(passed: false, failedStep: step, failedSlot: slot, failureCode: code, reason: reason, steps: steps)
        }
        func mark(_ step: Int, _ status: SiteVerificationStepStatus) {
            steps.append(.init(step: step, name: stepNames[step] ?? "Step \(step)", status: status))
        }

        let scriptsByID = await MainActor.run { Dictionary(uniqueKeysWithValues: scriptStore.scripts.map { ($0.id, $0) }) }
        let snapshot = await pageToolBridge.collectTools()
        for slot in providedSlots where !snapshot.scriptTools.contains(where: { $0.ownerID == candidate.id && $0.name == slot.rawValue }) {
            return fail(1, slot: slot, code: .threw, "no tool named \(slot.rawValue) was registered")
        }
        mark(1, .passed)

        let rawThread = !candidate.metadata.threadMatches.isEmpty ? candidate.metadata.threadMatches : (existingState?.threadMatch ?? [])
        let rawList = !candidate.metadata.listMatches.isEmpty ? candidate.metadata.listMatches : (existingState?.listMatch ?? [])
        let threadPatterns: [MatchPattern]
        switch validateSubMatchPatterns(rawThread, label: "thread_match", siteHost: siteHost) {
        case .success(let p): threadPatterns = p
        case .failure(let e): return fail(2, slot: .readTopic, code: .shape, e.message)
        }
        let listPatterns: [MatchPattern]
        switch validateSubMatchPatterns(rawList, label: "list_match", siteHost: siteHost) {
        case .success(let p): listPatterns = p
        case .failure(let e): return fail(2, slot: .listLatest, code: .shape, e.message)
        }

        var validatedTestURLs: [URL] = []
        for raw in rawTestURLs {
            guard let u = SiteToolState.sameSiteURL(raw, host: siteHost) else {
                return fail(2, slot: providedSlots.first, code: .shape, "test URL '\(raw)' is not an http(s) URL on \(siteHost)")
            }
            validatedTestURLs.append(u)
        }

        var decodedThreads: [(url: URL, envelope: LearnedToolResult<ThreadShape>, durationMs: Double)] = []
        var decodedLatest: (listURL: String, envelope: LearnedToolResult<ListShape>, durationMs: Double)?
        var decodedSearch: (listURL: String, query: String, envelope: LearnedToolResult<ListShape>, durationMs: Double)?

        if providedSlots.contains(.readTopic) {
            guard !threadPatterns.isEmpty else { return fail(2, slot: .readTopic, code: .shape, "thread_match is required for read_topic") }
            let sourceURLs = validatedTestURLs.isEmpty
                ? (existingState?.slot(.readTopic).testURLs.compactMap { SiteToolState.sameSiteURL($0, host: siteHost) } ?? []) : validatedTestURLs
            if providedSlots.count == 1 {
                for u in sourceURLs where !threadPatterns.contains(where: { $0.matches(url: u) }) {
                    return fail(2, slot: .readTopic, code: .shape, "'\(u.absoluteString)' does not match thread_match")
                }
            }
            let matching = providedSlots.count == 1 ? sourceURLs : sourceURLs.filter { u in threadPatterns.contains { $0.matches(url: u) } }
            var distinct: [URL] = [], seenKeys: Set<String> = []
            for u in matching where seenKeys.insert(SiteToolState.canonicalThreadKey(for: u)).inserted { distinct.append(u) }
            guard distinct.count >= 2 else {
                return fail(2, slot: .readTopic, code: .shape, "read_topic requires two different thread test_urls matching thread_match (got '\(sourceURLs.first?.absoluteString ?? openPageURL)')")
            }
            var pair = [distinct[0], distinct[1]]
            if threadPatterns.contains(where: { $0.matches(urlString: openPageURL) }) {
                guard let idx = distinct.firstIndex(where: { SiteToolState.isSameDocument($0, openURLString: openPageURL) }),
                      let other = distinct.first(where: { !SiteToolState.isSameDocument($0, openURLString: openPageURL) }) else {
                    return fail(2, slot: .readTopic, code: .shape, "one of test_urls must be the open thread page '\(openPageURL)' (got '\(pair[0].absoluteString)', '\(pair[1].absoluteString)')")
                }
                pair = [distinct[idx], other]
            }
            for u in pair {
                let argsJSON = JSONValue.encodeCompactJSON(["url": .string(u.absoluteString), "page": .int(1)])
                switch await callBounded(pageToolBridge: pageToolBridge, scriptID: candidate.id, slot: .readTopic, argsJSON: argsJSON, label: u.absoluteString, limits: limits) {
                case .stepFailed(let s, let c, let msg): return fail(s, slot: .readTopic, code: c, msg)
                case .ok(let res):
                    if let err = validateStrictEnvelope(res.value, slot: .readTopic) { return fail(3, slot: .readTopic, code: .shape, err) }
                    guard let env = try? JSONDecoder().decode(LearnedToolResult<ThreadShape>.self, from: Data(res.json.utf8)) else {
                        return fail(3, slot: .readTopic, code: .shape, "invalid ThreadShape envelope for '\(u.absoluteString)'")
                    }
                    decodedThreads.append((u, env, res.durationMs))
                }
            }
        }

        let threadKeys = Set(decodedThreads.map { SiteToolState.canonicalThreadKey(for: $0.url) })
        func resolveListURL(for slot: SiteToolSlot) -> Result<String, SiteVerifierError> {
            let nonThread = validatedTestURLs.filter { !threadKeys.contains(SiteToolState.canonicalThreadKey(for: $0)) }
            let chosen = nonThread.first?.absoluteString ?? existingState?.slot(slot).testURLs.first ?? openPageURL
            guard SiteToolState.sameSiteURL(chosen, host: siteHost) != nil else { return .failure(.init("list test URL '\(chosen)' is not on \(siteHost)")) }
            if !listPatterns.isEmpty, !listPatterns.contains(where: { $0.matches(urlString: chosen) }) { return .failure(.init("'\(chosen)' does not match list_match")) }
            return .success(chosen)
        }

        if providedSlots.contains(.listLatest) {
            let listURL: String
            switch resolveListURL(for: .listLatest) {
            case .success(let u): listURL = u
            case .failure(let e): return fail(2, slot: .listLatest, code: .shape, e.message)
            }
            switch await callBounded(pageToolBridge: pageToolBridge, scriptID: candidate.id, slot: .listLatest, argsJSON: "{}", label: listURL, limits: limits) {
            case .stepFailed(let s, let c, let msg): return fail(s, slot: .listLatest, code: c, msg)
            case .ok(let res):
                if let err = validateStrictEnvelope(res.value, slot: .listLatest) { return fail(3, slot: .listLatest, code: .shape, err) }
                guard let env = try? JSONDecoder().decode(LearnedToolResult<ListShape>.self, from: Data(res.json.utf8)) else {
                    return fail(3, slot: .listLatest, code: .shape, "invalid ListShape envelope")
                }
                decodedLatest = (listURL, env, res.durationMs)
            }
        }

        if providedSlots.contains(.searchForum) {
            let listURL: String
            switch resolveListURL(for: .searchForum) {
            case .success(let u): listURL = u
            case .failure(let e): return fail(2, slot: .searchForum, code: .shape, e.message)
            }
            var titles: [String] = decodedLatest?.envelope.shape.items.map(\.title) ?? []
            if titles.isEmpty, let ls = existingState?.slot(.listLatest), ls.status == .learned, let lid = ls.scriptID,
               scriptsByID[lid]?.isEnabled == true,
               case .success(let lr) = await pageToolBridge.callScriptTool(scriptID: lid, name: SiteToolSlot.listLatest.rawValue, argumentsJSON: "{}", timeout: limits.callTimeout, maxResponseBytes: limits.maxResponseBytes),
               let lenv = try? JSONDecoder().decode(LearnedToolResult<ListShape>.self, from: Data(lr.json.utf8)) {
                titles = lenv.shape.items.map(\.title)
            }
            if titles.isEmpty {
                let pageTitle = await bridge.currentPageMetadata().title
                let links = (try? await bridge.pageLinks().map(\.text)) ?? []
                let headings = (try? await bridge.readPage(mode: .text, selector: "h1, h2, h3", maxLength: 2_000)) ?? ""
                let sample = (try? await bridge.readPage(mode: .text, selector: nil, maxLength: 2_000)) ?? ""
                titles = links + [headings, pageTitle, sample]
            }
            guard let word = pickSearchWord(from: titles) else { return fail(2, slot: .searchForum, code: .shape, "could not pick a search word on '\(listURL)'") }
            let argsJSON = JSONValue.encodeCompactJSON(["query": .string(word)])
            switch await callBounded(pageToolBridge: pageToolBridge, scriptID: candidate.id, slot: .searchForum, argsJSON: argsJSON, label: "\(listURL) (query '\(word)')", limits: limits) {
            case .stepFailed(let s, let c, let msg): return fail(s, slot: .searchForum, code: c, msg)
            case .ok(let res):
                if let err = validateStrictEnvelope(res.value, slot: .searchForum) { return fail(3, slot: .searchForum, code: .shape, err) }
                guard let env = try? JSONDecoder().decode(LearnedToolResult<ListShape>.self, from: Data(res.json.utf8)) else {
                    return fail(3, slot: .searchForum, code: .shape, "invalid ListShape envelope")
                }
                decodedSearch = (listURL, word, env, res.durationMs)
            }
        }
        mark(2, .passed); mark(3, .passed)

        if !decodedThreads.isEmpty {
            for entry in decodedThreads {
                let t = entry.envelope.shape
                if t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return fail(4, slot: .readTopic, code: .shape, "thread title is empty for '\(entry.url.absoluteString)'") }
                guard SiteToolState.sameSiteURL(t.url, host: siteHost) != nil else { return fail(4, slot: .readTopic, code: .shape, "thread url '\(t.url)' is not an absolute URL on \(siteHost)") }
                guard !t.posts.isEmpty else { return fail(4, slot: .readTopic, code: .noPosts, "thread '\(entry.url.absoluteString)' returned no posts") }
                var prevNumber = 0, emptyAuthorNums: [Int] = []
                for p in t.posts {
                    if p.number <= prevNumber { return fail(4, slot: .readTopic, code: .shape, "post #\(p.number) is not in rising order") }
                    prevNumber = p.number
                    if p.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return fail(4, slot: .readTopic, code: .noPosts, "post #\(p.number) has an empty body") }
                    if containsHTMLMarkup(p.body) { return fail(4, slot: .readTopic, code: .shape, "post #\(p.number) body contains HTML markup") }
                    if p.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyAuthorNums.append(p.number) }
                }
                if emptyAuthorNums.count * 10 > t.posts.count {
                    let bad = emptyAuthorNums[min(t.posts.count / 10, emptyAuthorNums.count - 1)]
                    return fail(4, slot: .readTopic, code: .shape, "post #\(bad) has an empty author (at least 9 posts in 10 must have a non-empty author)")
                }
            }
            if decodedThreads.count >= 2, decodedThreads.allSatisfy({ $0.envelope.shape.posts.count < 2 }) {
                return fail(4, slot: .readTopic, code: .shape, "post #\(decodedThreads[0].envelope.shape.posts.first?.number ?? 1): neither thread returned at least 2 posts")
            }
            mark(4, .passed)
        } else { mark(4, .skipped) }

        let existingReadLearned = existingState?.slot(.readTopic).status == .learned
            && (existingState?.slot(.readTopic).scriptID).flatMap({ scriptsByID[$0] }) != nil
        let reqThreadPatterns = (!decodedThreads.isEmpty || existingReadLearned) ? threadPatterns : []
        if decodedLatest != nil || decodedSearch != nil {
            if let latest = decodedLatest, let err = checkListItems(latest.envelope.shape.items, minCount: 5, label: "list_latest", siteHost: siteHost, threadMatch: reqThreadPatterns) {
                return fail(5, slot: .listLatest, code: latest.envelope.shape.items.isEmpty ? .noPosts : .shape, err)
            }
            if let search = decodedSearch, let err = checkListItems(search.envelope.shape.items, minCount: 1, label: "search_forum ('\(search.query)')", siteHost: siteHost, threadMatch: reqThreadPatterns) {
                return fail(5, slot: .searchForum, code: search.envelope.shape.items.isEmpty ? .noPosts : .shape, err)
            }
            mark(5, .passed)
        } else { mark(5, .skipped) }

        if decodedThreads.count >= 2 {
            let t1 = decodedThreads[0].envelope.shape, t2 = decodedThreads[1].envelope.shape
            if foldWhitespace(t1.title) == foldWhitespace(t2.title) || foldWhitespace(t1.posts[0].body) == foldWhitespace(t2.posts[0].body) {
                return fail(6, slot: .readTopic, code: .shape, "both URLs returned the same thread")
            }
            mark(6, .passed)
        } else { mark(6, .skipped) }

        if let openEntry = decodedThreads.first(where: { SiteToolState.isSameDocument($0.url, openURLString: openPageURL) }) {
            let pageFolded = foldWhitespace((try? await bridge.readPage(mode: .text, selector: nil, maxLength: nil)) ?? "")
            let posts = openEntry.envelope.shape.posts
            var matched = 0, firstMissing: Int?
            for post in posts {
                let pfx = postStart(post.body)
                if !pfx.isEmpty, pageFolded.contains(pfx) { matched += 1 }
                else if firstMissing == nil { firstMissing = post.number }
            }
            if matched < min(2, posts.count) {
                return fail(7, slot: .readTopic, code: .shape, "post #\(firstMissing ?? posts.first?.number ?? 1) is not on the page")
            }
            mark(7, .passed)
        } else { mark(7, .skipped) }

        mark(8, .passed)
        if let ext = firstExternalHost(in: candidate.js + "\n" + candidate.css, siteHost: siteHost) {
            return fail(9, slot: providedSlots.first, code: .shape, "source names external host '\(ext)'")
        }
        mark(9, .passed)

        var slotReports: [SiteToolSlot: SiteSlotVerification] = [:], headerURLs: [String] = []
        func addHeader(_ u: String) { if !headerURLs.contains(u) { headerURLs.append(u) } }
        if !decodedThreads.isEmpty {
            let urls = decodedThreads.map(\.url.absoluteString); urls.forEach(addHeader)
            let starts = Dictionary(uniqueKeysWithValues: decodedThreads.map { ($0.url.absoluteString, Array($0.envelope.shape.posts.prefix(2).map { postStart($0.body) }.filter { !$0.isEmpty })) })
            slotReports[.readTopic] = SiteSlotVerification(slot: .readTopic, primaryURL: urls[0], testURLs: urls, counts: decodedThreads.map(\.envelope.shape.posts.count), postStarts: starts, durationMs: decodedThreads.reduce(0) { $0 + $1.durationMs })
        }
        if let latest = decodedLatest {
            addHeader(latest.listURL)
            slotReports[.listLatest] = SiteSlotVerification(slot: .listLatest, primaryURL: latest.listURL, testURLs: [latest.listURL], counts: [latest.envelope.shape.items.count], durationMs: latest.durationMs)
        }
        if let search = decodedSearch {
            addHeader(search.listURL)
            slotReports[.searchForum] = SiteSlotVerification(slot: .searchForum, primaryURL: search.listURL, testURLs: [search.listURL], counts: [search.envelope.shape.items.count], durationMs: search.durationMs, searchQuery: search.query)
        }
        let summary = providedSlots.compactMap { slotReports[$0]?.summary }.joined(separator: "; ")
        return SiteToolVerificationReport(passed: true, steps: steps, slots: slotReports, headerTestURLs: headerURLs, verificationSummary: summary)
    }

    private enum BoundedOutcome { case ok(PageToolCallResult), stepFailed(step: Int, code: SiteFailureCode, message: String) }

    @MainActor
    private static func callBounded(
        pageToolBridge: PageToolBridge, scriptID: String, slot: SiteToolSlot, argsJSON: String, label: String, limits: Limits
    ) async -> BoundedOutcome {
        let timeText = limits.callTimeout.rounded() == limits.callTimeout ? "\(Int(limits.callTimeout))s" : String(format: "%.2fs", limits.callTimeout)
        let sizeText = limits.maxResponseBytes % (1_024 * 1_024) == 0 ? "\(limits.maxResponseBytes / (1_024 * 1_024)) MB" : "\(limits.maxResponseBytes) bytes"
        switch await pageToolBridge.callScriptTool(scriptID: scriptID, name: slot.rawValue, argumentsJSON: argsJSON, timeout: limits.callTimeout, maxResponseBytes: limits.maxResponseBytes) {
        case .success(let res):
            if res.durationMs > limits.callTimeout * 1_000 { return .stepFailed(step: 8, code: .timeout, message: "\(slot.rawValue) exceeded \(timeText) time limit on \(label)") }
            if res.byteCount > limits.maxResponseBytes { return .stepFailed(step: 8, code: .shape, message: "\(slot.rawValue) exceeded \(sizeText) size limit on \(label)") }
            return .ok(res)
        case .failure(let err):
            if err.code == .timedOut { return .stepFailed(step: 8, code: .timeout, message: "\(slot.rawValue) timed out after \(timeText) on \(label)") }
            if err.code == .responseTooLarge { return .stepFailed(step: 8, code: .shape, message: "\(slot.rawValue) exceeded \(sizeText) size limit on \(label) (\(err.message))") }
            return .stepFailed(step: 2, code: .threw, message: "\(slot.rawValue) failed on \(label): \(err.message)")
        }
    }

    private static func checkListItems(_ items: [ListShape.Item], minCount: Int, label: String, siteHost: String, threadMatch: [MatchPattern]) -> String? {
        var seen: Set<String> = []
        for (idx, item) in items.enumerated() {
            let n = idx + 1
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "item #\(n) has an empty title" }
            guard let validURL = SiteToolState.sameSiteURL(item.url, host: siteHost) else { return "item #\(n) url '\(item.url)' is not an absolute URL on \(siteHost)" }
            if !seen.insert(SiteToolState.canonicalThreadKey(for: validURL)).inserted { return "item #\(n) duplicates url '\(item.url)'" }
        }
        if items.count < minCount { return "\(label) returned \(items.count) item(s); expected at least \(minCount)" }
        if !threadMatch.isEmpty, !items.contains(where: { it in threadMatch.contains { $0.matches(urlString: it.url) } }) {
            return "item #1 ('\(items[0].url)') and all \(items.count) items missed thread_match"
        }
        return nil
    }

    static func validateStrictEnvelope(_ root: JSONValue, slot: SiteToolSlot) -> String? {
        func reqStr(_ d: [String: JSONValue], _ k: String, _ p: String) -> String? {
            guard let v = d[k], !v.isNull else { return "missing required field '\(p)'" }
            return v.stringValue == nil ? "mistyped field '\(p)' (expected string)" : nil
        }
        func optStr(_ d: [String: JSONValue], _ k: String, _ p: String) -> String? {
            guard let v = d[k], !v.isNull else { return nil }
            return v.stringValue == nil ? "mistyped field '\(p)' (expected string)" : nil
        }
        func optInt(_ d: [String: JSONValue], _ k: String, _ p: String) -> String? {
            guard let v = d[k], !v.isNull else { return nil }
            return v.strictIntValue == nil ? "mistyped field '\(p)' (expected integer)" : nil
        }
        guard case .object(let env) = root else { return "result must be a JSON object envelope" }
        for k in ["page", "total_pages", "next_page"] { if let e = optInt(env, k, k) { return e } }
        if let cpo = env["current_page_only"], !cpo.isNull, cpo.strictBoolValue == nil { return "mistyped field 'current_page_only' (expected boolean)" }
        guard let sv = env["shape"], !sv.isNull else { return "missing required field 'shape'" }
        guard case .object(let shape) = sv else { return "mistyped field 'shape' (expected object)" }
        switch slot {
        case .readTopic:
            for k in ["title", "url"] { if let e = reqStr(shape, k, "shape.\(k)") { return e } }
            if let e = optStr(shape, "id", "shape.id") ?? optInt(shape, "total_posts", "shape.total_posts") { return e }
            guard let pv = shape["posts"], !pv.isNull else { return "missing required field 'shape.posts'" }
            guard case .array(let posts) = pv else { return "mistyped field 'shape.posts' (expected array)" }
            for (i, postVal) in posts.enumerated() {
                let pfx = "shape.posts[\(i)]"
                guard case .object(let p) = postVal else { return "mistyped field '\(pfx)' (expected object)" }
                guard let n = p["number"], !n.isNull else { return "missing required field '\(pfx).number'" }
                if n.strictIntValue == nil { return "mistyped field '\(pfx).number' (expected integer)" }
                if let e = reqStr(p, "author", "\(pfx).author") ?? reqStr(p, "body", "\(pfx).body") ?? optStr(p, "date", "\(pfx).date")
                    ?? optInt(p, "score", "\(pfx).score") ?? optInt(p, "reply_to", "\(pfx).reply_to") { return e }
            }
        case .listLatest, .searchForum:
            guard let iv = shape["items"], !iv.isNull else { return "missing required field 'shape.items'" }
            guard case .array(let items) = iv else { return "mistyped field 'shape.items' (expected array)" }
            for (i, itemVal) in items.enumerated() {
                let pfx = "shape.items[\(i)]"
                guard case .object(let it) = itemVal else { return "mistyped field '\(pfx)' (expected object)" }
                if let e = reqStr(it, "title", "\(pfx).title") ?? reqStr(it, "url", "\(pfx).url")
                    ?? optStr(it, "id", "\(pfx).id") ?? optStr(it, "last_activity", "\(pfx).last_activity")
                    ?? optStr(it, "excerpt", "\(pfx).excerpt") ?? optStr(it, "author", "\(pfx).author")
                    ?? optInt(it, "posts_count", "\(pfx).posts_count") { return e }
                if let hv = it["hits"], !hv.isNull {
                    guard case .array(let hits) = hv else { return "mistyped field '\(pfx).hits' (expected array)" }
                    for (hi, hVal) in hits.enumerated() {
                        let hp = "\(pfx).hits[\(hi)]"
                        guard case .object(let h) = hVal else { return "mistyped field '\(hp)' (expected object)" }
                        if let e = optInt(h, "number", "\(hp).number") ?? optStr(h, "author", "\(hp).author") ?? optStr(h, "blurb", "\(hp).blurb") { return e }
                    }
                }
            }
        }
        return nil
    }
}
