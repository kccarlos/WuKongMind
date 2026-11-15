import Foundation

// MARK: - Live voice (WukongMind/Voice)
//
// AppModel is the voice layer's navigator: the tools call the navigation
// layer (AppModel+Navigation.swift) and the silent context reads the page.
// `VoiceController` (Voice/VoiceController.swift) starts sessions from the
// browser bar's microphone through `makeVoiceSession`.

extension AppModel: VoiceNavigator {
    /// The text of every post on screen, without hidden ones.
    func readVisible() async -> BrowseResult {
        guard currentTopicRef != nil else {
            return BrowseResult(status: .unavailable, shown: "No topic is open.")
        }
        let posts = await postsOnScreenWithText(limit: 4)
        guard !posts.isEmpty else {
            return BrowseResult(status: .notFound, shown: "No posts are on screen.")
        }
        let texts = posts.map { BrowseText.content(of: $0) }
        let numbers = posts.map { "\($0.number)" }.joined(separator: ", ")
        return BrowseResult(status: .read, shown: "Posts \(numbers) on screen", content: texts.joined(separator: "\n\n"))
    }

    /// The posts on screen (at most `limit`) with their text: the voice
    /// `read` tool and Translate Posts on Screen.
    func postsOnScreenWithText(limit: Int) async -> [BrowsePostText] {
        guard let ref = currentTopicRef else { return [] }
        let posts = await postsOnScreen()
        var texts: [BrowsePostText] = []
        for post in posts.prefix(limit) {
            if let text = await postText(post.number, in: ref, facts: topicOverviews[ref.topicKey]?.facts) {
                texts.append(text)
            }
        }
        return texts
    }

    /// Translate Posts on Screen: up to eight posts.
    func postsToTranslate() async -> [BrowsePostText] {
        await postsOnScreenWithText(limit: 8)
    }

    // MARK: Hand-off (hand_off_to_agent)

    var isHandingOff: Bool { agentHandOff.isRunning }
    func startHandOff(_ request: String) -> String? { agentHandOff.start(request) }
    func handOffOutcome() async -> VoiceHandOffOutcome { await agentHandOff.outcome() }
    func cancelHandOff() -> Bool { agentHandOff.cancel() }
    var handOffProgress: String? { agentHandOff.progress }

    /// The page's site, else the registry's fallback.
    var voiceSite: VoiceSite {
        sites.voiceSite(for: pageContext.site)
    }

    var pageTitle: String? {
        if let topicTitle = pageContext.topic?.title.trimmingCharacters(in: .whitespacesAndNewlines), !topicTitle.isEmpty {
            return topicTitle
        }
        if let webTitle = browser.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !webTitle.isEmpty {
            return webTitle
        }
        let current = browser.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty || current == ForumBrowserModel.defaultPageTitle ? nil : current
    }

    func voiceTopicBrief() async -> VoiceTopicBrief? {
        guard let ref = currentTopicRef else { return nil }
        let overview = await topicOverview(siteURL: ref.siteURL, topicID: ref.topicID)
        let facts = overview?.facts
        let opening = facts != nil ? await postText(1, in: ref, facts: facts)?.text : nil
        let top = (facts?.posts ?? [])
            .filter { ($0.likeCount ?? 0) > 0 }
            .sorted { ($0.likeCount ?? 0) > ($1.likeCount ?? 0) }
            .prefix(5)
            .map { VoiceTopicBrief.Post(number: $0.number, username: $0.username, likes: $0.likeCount) }
        let solution = facts?.acceptedAnswer.map { answer in
            let username = answer.username ?? facts?.posts.first { $0.number == answer.postNumber }?.username ?? "someone"
            return VoiceTopicBrief.Post(number: answer.postNumber, username: username)
        }
        let summary = sessions[ref.topicKey].flatMap { session in
            let trimmed = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : session.summary
        }
        return VoiceTopicBrief(
            topicKey: ref.topicKey,
            title: ref.title ?? overview?.title ?? "",
            forumName: pageContext.forumName,
            opening: opening,
            openingPoster: facts?.openingPoster,
            postCount: facts?.postsCount ?? overview?.postCount,
            solution: solution,
            topPosts: Array(top),
            summary: summary
        )
    }

    func postsOnScreen() async -> [VisiblePost] {
        await browser.postsOnScreen()
    }

    func pageLinks() async -> [PageLink] {
        guard !browser.showsForumsHome else { return [] }
        return (try? await browser.agentBridge.pageLinks()) ?? []
    }

    var openTopicID: String? {
        guard !browser.isForumsHomeRequested, pageContext.state == .topic else { return nil }
        return pageContext.topic?.topicID
    }

    var hasOpenPage: Bool {
        !browser.showsForumsHome && (browser.webView.url != nil || browser.currentURL != nil)
    }

    func pageReadableText() async -> String? {
        guard hasOpenPage,
              let body = (try? await browser.agentBridge.readablePageText())?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return nil }
        guard let rawTitle = pageTitle?
            .replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawTitle.isEmpty else {
            return body
        }
        let firstLine = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let titleAlreadyLeads = firstLine.caseInsensitiveCompare(rawTitle) == .orderedSame
            || firstLine.localizedCaseInsensitiveContains(rawTitle)
            || (firstLine.count >= max(8, rawTitle.count / 2) && rawTitle.localizedCaseInsensitiveContains(firstLine))
        return titleAlreadyLeads ? body : "\(rawTitle)\n\n\(body)"
    }

    var linkPageIdentity: String {
        if browser.showsForumsHome { return "home" }
        return VoiceLinkState.pageKey(url: browser.webView.url ?? browser.currentURL, page: pageContext)
    }

    /// Queues the topic's summary in the existing pipeline and waits for it
    /// (at most two minutes).
    func quickSummary(topicKey: String) async -> String? {
        if let saved = sessions[topicKey], !saved.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved.summary
        }
        guard let topic = pageContext.topic, topic.topicKey == topicKey else { return nil }
        enqueueSummary(for: topic)
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return nil }
            if let session = sessions[topicKey], !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return session.summary
            }
            if !activities.contains(where: { $0.topicKey == topicKey && $0.type == .summary && !$0.status.isTerminal }) {
                return nil
            }
        }
        return nil
    }

    // MARK: Session

    /// Providers the user can talk to: those with a key.
    var availableVoiceProviders: [VoiceProvider] {
        if VoiceDebug.isFake { return [.aiStudio] }
        return VoiceProvider.allCases.filter { !settings.configuration(for: $0.keyProvider).apiKey.isEmpty }
    }

    /// The provider a session would use: the chosen one, else one with a key.
    var voiceProvider: VoiceProvider? {
        let available = availableVoiceProviders
        return available.contains(settings.voice.provider) ? settings.voice.provider : available.first
    }

    /// The browser bar shows the microphone when voice is enabled on this device.
    var showsVoiceButton: Bool {
        settings.voiceEnabled
    }

    /// The configuration for a session with the chosen provider (falling
    /// back to the one with a key), or why there can't be one.
    func voiceConfiguration() -> Result<VoiceSession.Configuration, VoiceSession.Failure> {
        guard settings.voiceEnabled else { return .failure(.disabled) }
        guard let provider = voiceProvider else { return .failure(.noKey) }
        if VoiceDebug.isFake {
            return .success(VoiceSession.Configuration(endpoint: .aiStudio, apiKey: "fake-key", settings: settings.voice))
        }
        let configuration = settings.configuration(for: provider.keyProvider)
        let endpoint: GeminiLive.Endpoint
        switch provider {
        case .aiStudio:
            endpoint = .aiStudio
        case .vertex:
            let project = GeminiLive.Endpoint.vertexProject(fromBaseURL: configuration.baseURL)
                ?? settings.voice.vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint = .vertex(project: project, location: GeminiLive.Endpoint.vertexLocation)
        }
        return .success(VoiceSession.Configuration(
            endpoint: endpoint,
            apiKey: configuration.apiKey,
            settings: settings.voice
        ))
    }

    /// A session on the current page, wired to the page changes. The caller
    /// starts it (on the user's tap) and keeps it.
    func makeVoiceSession(
        audio: VoiceAudioIO,
        transport: @escaping LiveTransportFactory = { WebSocketLiveTransport() }
    ) -> Result<VoiceSession, VoiceSession.Failure> {
        voiceConfiguration().map { configuration in
            #if DEBUG
            let usageStore: VoiceUsageStore? = suppressesPersistence ? nil : VoiceUsageStore()
            #else
            let usageStore: VoiceUsageStore? = VoiceUsageStore()
            #endif
            let session = VoiceSession(
                configuration: configuration,
                transport: transport,
                audio: audio,
                navigator: self,
                usage: usageStore
            )
            session.tools.registryBuilder = { [weak self] browse in
                self?.voiceToolRegistry(browse: browse) ?? ToolRegistry(tools: ToolRegistry.browseTools(browse: browse))
            }
            // Voice turns join the one conversation (design-one-loop.md "Voice").
            session.onTranscript = { [weak self] role, text, date in self?.browserAgent.appendVoiceTurn(role, text: text, at: date) }
            let subscription = pageChanges.sink { [weak session] page in session?.pageChanged(page) }
            voicePageSubscription = subscription
            // The topic brief wants the post count and the solution.
            prefetchesTopicFacts = true
            return session
        }
    }

    /// The voice session's tools on the page as it is now: the registry's
    /// `.voice` tools, with a fresh forum read budget per call.
    func voiceToolRegistry(browse: BrowseToolContext) -> ToolRegistry {
        let forum = makeForumToolContext()
        browse.isOnForum = forum != nil
        return ToolRegistry.m3(context: AgentToolContext(
            bridge: browser.agentBridge,
            workspace: agentWorkspace,
            scriptStore: scriptStore,
            settings: AgentToolSettings(redactedSecrets: browserAgentRuntimeConfig.redactedSecrets),
            forum: forum,
            capabilities: capabilityToolContext,
            browse: browse
        ), surface: .voice)
    }

    /// The session is over: stop feeding it and fetching facts for it.
    func voiceSessionEnded() {
        voicePageSubscription = nil
        prefetchesTopicFacts = false
    }
}
