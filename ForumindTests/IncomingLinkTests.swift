import XCTest
@testable import Forumind

final class IncomingLinkTests: XCTestCase {
    private var inboxDirectory: URL!

    override func setUpWithError() throws {
        inboxDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingLinkTests-\(UUID().uuidString)", isDirectory: true)
        SharedInbox.storageURLOverride = inboxDirectory
            .appendingPathComponent(SharedInbox.fileName, isDirectory: false)
    }

    override func tearDownWithError() throws {
        SharedInbox.storageURLOverride = nil
        try? FileManager.default.removeItem(at: inboxDirectory)
    }

    // MARK: - URL building and parsing

    func testRoundTripPreservesAwkwardURLAndTitle() throws {
        let pageURL = try XCTUnwrap(
            URL(string: "https://meta.discourse.org/t/some-topic/123/4?u=a&b=1+2&q=%E2%9C%93#post_4")
        )
        let request = IncomingLinkRequest(
            url: pageURL,
            action: .summary,
            title: "Cards & Points = Fun + Games ✓"
        )

        let link = IncomingLink.url(for: request)
        XCTAssertEqual(link.scheme, "forumind")
        XCTAssertEqual(link.host, "open")

        let parsed = try XCTUnwrap(IncomingLink.parse(link, now: request.createdAt))
        XCTAssertEqual(parsed, request)
    }

    func testEveryActionRoundTrips() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://forum.example.com/latest"))
        for action in IncomingLinkRequest.Action.allCases {
            let request = IncomingLinkRequest(url: pageURL, action: action)
            let parsed = IncomingLink.parse(IncomingLink.url(for: request))
            XCTAssertEqual(parsed?.action, action)
            XCTAssertEqual(parsed?.id, request.id)
            XCTAssertNil(parsed?.title)
        }
    }

    func testParsesMinimalLinkWithDefaultAction() throws {
        let link = try XCTUnwrap(
            URL(string: "forumind://open?url=https%3A%2F%2Fforum.example.com%2Ft%2Ftopic%2F42")
        )
        let parsed = try XCTUnwrap(IncomingLink.parse(link))
        XCTAssertEqual(parsed.url.absoluteString, "https://forum.example.com/t/topic/42")
        XCTAssertEqual(parsed.action, .open)
        XCTAssertNil(parsed.title)
    }

    func testUnknownActionFallsBackToOpen() throws {
        let link = try XCTUnwrap(
            URL(string: "forumind://open?url=https://a.example/t/1&action=explode")
        )
        XCTAssertEqual(IncomingLink.parse(link)?.action, .open)
        let upper = try XCTUnwrap(
            URL(string: "forumind://open?url=https://a.example/t/1&action=CHAT")
        )
        XCTAssertEqual(IncomingLink.parse(upper)?.action, .chat)
    }

    func testRejectsNonWebPagesAndForeignLinks() throws {
        let rejected = [
            "forumind://open?url=javascript%3Aalert(1)",
            "forumind://open?url=file%3A%2F%2F%2Fetc%2Fpasswd",
            "forumind://open?url=ftp%3A%2F%2Fexample.com",
            "forumind://open?url=https%3A%2F%2F",
            "forumind://open?action=summary",
            "forumind://open",
            "forumind://settings?url=https%3A%2F%2Fa.example",
            "https://open?url=https%3A%2F%2Fa.example",
            "otherapp://open?url=https%3A%2F%2Fa.example"
        ]
        for string in rejected {
            let link = try XCTUnwrap(URL(string: string), string)
            XCTAssertNil(IncomingLink.parse(link), string)
        }
    }

    func testParseNormalizesTitleAndIgnoresBadID() throws {
        let link = try XCTUnwrap(
            URL(string: "forumind://open?url=https://a.example/t/1&title=%20%20Hello%0A%20world%20&id=nope")
        )
        let parsed = try XCTUnwrap(IncomingLink.parse(link))
        XCTAssertEqual(parsed.title, "Hello world")
    }

    // MARK: - Shared text

    func testExtractsURLFromChromeStyleText() {
        XCTAssertEqual(
            IncomingLink.extractWebURL(from: "Great thread\nhttps://meta.discourse.org/t/abc/99")?
                .absoluteString,
            "https://meta.discourse.org/t/abc/99"
        )
        XCTAssertEqual(
            IncomingLink.extractWebURL(from: "  https://a.example/t/x/1?page=2  ")?.absoluteString,
            "https://a.example/t/x/1?page=2"
        )
        XCTAssertEqual(
            IncomingLink.extractWebURL(from: "See (https://a.example/t/x/1).")?.host,
            "a.example"
        )
    }

    func testExtractIgnoresTextWithoutWebURL() {
        XCTAssertNil(IncomingLink.extractWebURL(from: ""))
        XCTAssertNil(IncomingLink.extractWebURL(from: "just some words"))
        XCTAssertNil(IncomingLink.extractWebURL(from: "mailto:someone@example.com"))
    }

    // MARK: - Shared inbox

    func testInboxDrainsOldestFirstAndEmpties() throws {
        let now = Date()
        let first = makeRequest(createdAt: now.addingTimeInterval(-60), action: .chat)
        let second = makeRequest(createdAt: now.addingTimeInterval(-30), action: .agent)

        XCTAssertTrue(SharedInbox.enqueue(second, now: now))
        XCTAssertTrue(SharedInbox.enqueue(first, now: now))

        XCTAssertEqual(SharedInbox.drainAll(now: now), [first, second])
        XCTAssertEqual(SharedInbox.drainAll(now: now), [])
    }

    func testInboxDropsExpiredEntries() {
        let now = Date()
        let stale = makeRequest(createdAt: now.addingTimeInterval(-(SharedInbox.maximumAge + 60)))
        let fresh = makeRequest(createdAt: now.addingTimeInterval(-60))
        SharedInbox.enqueue(stale, now: stale.createdAt)
        SharedInbox.enqueue(fresh, now: now)

        XCTAssertEqual(SharedInbox.drainAll(now: now), [fresh])
    }

    func testInboxRemoveByIDAndDeduplicatesEnqueue() {
        let now = Date()
        let kept = makeRequest(createdAt: now.addingTimeInterval(-20))
        var removed = makeRequest(createdAt: now.addingTimeInterval(-10))
        SharedInbox.enqueue(kept, now: now)
        SharedInbox.enqueue(removed, now: now)
        removed.action = .summary
        SharedInbox.enqueue(removed, now: now)

        SharedInbox.remove(id: removed.id)
        XCTAssertEqual(SharedInbox.drainAll(now: now), [kept])
    }

    func testInboxCapsStoredEntries() {
        let now = Date()
        let requests = (0..<(SharedInbox.maximumCount + 5)).map {
            makeRequest(createdAt: now.addingTimeInterval(TimeInterval($0 - 100)))
        }
        requests.forEach { SharedInbox.enqueue($0, now: now) }

        let drained = SharedInbox.drainAll(now: now)
        XCTAssertEqual(drained.count, SharedInbox.maximumCount)
        XCTAssertEqual(drained.last, requests.last)
    }

    func testInboxIgnoresCorruptFile() throws {
        let fileURL = try XCTUnwrap(SharedInbox.storageURL)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(SharedInbox.drainAll(), [])
        let request = makeRequest(createdAt: Date())
        XCTAssertTrue(SharedInbox.enqueue(request))
        XCTAssertEqual(SharedInbox.drainAll(), [request])
    }

    func testInboxRemoveReportsWhetherTheRequestWasQueued() {
        let now = Date()
        let queued = makeRequest(createdAt: now.addingTimeInterval(-5))
        let other = makeRequest(createdAt: now.addingTimeInterval(-4))
        SharedInbox.enqueue(queued, now: now)
        SharedInbox.enqueue(other, now: now)

        XCTAssertTrue(SharedInbox.remove(id: queued.id, now: now))
        XCTAssertFalse(SharedInbox.remove(id: queued.id, now: now))
        XCTAssertFalse(SharedInbox.remove(id: UUID(), now: now))
        // An expired entry does not vouch for a link.
        XCTAssertFalse(
            SharedInbox.remove(id: other.id, now: now.addingTimeInterval(SharedInbox.maximumAge + 60))
        )
    }

    // MARK: - Deep links and AI work

    /// Any app or page can open `forumind://open?...&action=summary`;
    /// without a matching inbox entry it opens the Assistant but spends no credits.
    @MainActor
    func testDeepLinkWithoutInboxEntryDoesNotStartASummary() throws {
        let app = makeReadyApp()
        let request = IncomingLinkRequest(url: topicURL, action: .summary)

        app.handleDeepLink(IncomingLink.url(for: request))
        deliverTopicPage(to: app)

        XCTAssertGreaterThan(app.assistantRequest, 0)
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertEqual(app.currentTopic?.topicKey, "forum.example.com/t/42")
        XCTAssertFalse(app.activities.contains { $0.type == .summary })
    }

    @MainActor
    func testShareExtensionDeepLinkStartsTheSummary() throws {
        let app = makeReadyApp()
        let request = IncomingLinkRequest(url: topicURL, action: .summary)
        XCTAssertTrue(SharedInbox.enqueue(request))

        app.handleDeepLink(IncomingLink.url(for: request))
        deliverTopicPage(to: app)

        XCTAssertTrue(app.activities.contains {
            $0.type == .summary && $0.topicKey == "forum.example.com/t/42"
        })
        XCTAssertEqual(SharedInbox.drainAll(), [])
        for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
    }

    @MainActor
    func testShareExtensionBeforeOnboardingOrTermsDoesNotStartAIWork() throws {
        // 1. Before onboarding completes (`!hasCompletedOnboarding`): share handoff must not auto-run.
        let unonboarded = makeReadyApp()
        unonboarded.settings.hasCompletedOnboarding = false
        XCTAssertFalse(unonboarded.acceptsSystemWork)
        let firstShare = IncomingLinkRequest(url: topicURL, action: .summary)
        XCTAssertTrue(SharedInbox.enqueue(firstShare))
        unonboarded.handleDeepLink(IncomingLink.url(for: firstShare))
        deliverTopicPage(to: unonboarded)
        defer {
            for record in unonboarded.activities where !record.status.isTerminal { unonboarded.cancel(record: record) }
        }
        XCTAssertFalse(
            unonboarded.activities.contains { $0.type == .summary },
            "Share deep link started AI summary before onboarding completed."
        )

        // 2. After onboarding, before Terms of Use are accepted (`needsTermsAcceptance`): inbox drain must not auto-run.
        let unaccepted = makeReadyApp()
        unaccepted.settings.acceptedTermsVersion = 0
        XCTAssertFalse(unaccepted.acceptsSystemWork)
        let termsShare = IncomingLinkRequest(url: topicURL, action: .summary)
        XCTAssertTrue(SharedInbox.enqueue(termsShare))
        unaccepted.drainSharedInbox()
        deliverTopicPage(to: unaccepted)
        defer {
            for record in unaccepted.activities where !record.status.isTerminal { unaccepted.cancel(record: record) }
        }
        XCTAssertFalse(
            unaccepted.activities.contains { $0.type == .summary },
            "Share inbox started AI summary before Terms of Use were accepted."
        )

        let chatShare = IncomingLinkRequest(url: topicURL, action: .chat)
        XCTAssertTrue(SharedInbox.enqueue(chatShare))
        unaccepted.drainSharedInbox()
        deliverTopicPage(to: unaccepted)
        XCTAssertFalse(
            unaccepted.activities.contains { $0.type == .pull },
            "Share inbox started topic pull before Terms of Use were accepted."
        )

        // 3. Without a configured provider, providerSetup waits until both onboarding and Terms are accepted.
        let unconfigured = AppModel(
            store: PersistentStore(
                fileURL: inboxDirectory.appendingPathComponent("unconfigured-state.json")
            )
        )
        unconfigured.settings.hasCompletedOnboarding = true
        unconfigured.settings.acceptedTermsVersion = 0
        let unconfiguredShare = IncomingLinkRequest(url: topicURL, action: .summary)
        unconfigured.handle(unconfiguredShare)
        deliverTopicPage(to: unconfigured)
        unconfigured.presentProviderSetupIfNeeded()
        XCTAssertEqual(unconfigured.needsProviderSetup, .assistant)
        XCTAssertNil(unconfigured.router.item, "Provider setup sheet must wait while Terms gate is active.")
        unconfigured.acceptTerms()
        unconfigured.presentProviderSetupIfNeeded()
        XCTAssertEqual(unconfigured.router.item, .providerSetup(.assistant))
    }

    @MainActor
    func testWordPressSlugShareAndLinkDropOpenAssistantAndStartWork() throws {
        let app = makeReadyApp()
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        defer {
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
        }

        let wpSiteURL = "https://blog.example.com"
        let sharedURL = URL(string: "https://blog.example.com/2026/05/hello-world")!
        let canonicalURL = URL(string: "https://blog.example.com/2026/05/hello-world/")!
        let request = IncomingLinkRequest(url: sharedURL, action: .summary, title: "Hello World")
        XCTAssertTrue(SharedInbox.enqueue(request))

        app.handleDeepLink(IncomingLink.url(for: request))

        // A late report from the previously open page must neither trigger nor cancel the share.
        deliverTopicPage(to: app)
        XCTAssertEqual(app.assistantRequest, 0)

        let wpTopic = ForumTopic(siteURL: wpSiteURL, topicID: "1001", url: canonicalURL, title: "Hello World")
        let wpContext = PageContext(
            url: canonicalURL,
            site: .wordpress,
            siteURL: wpSiteURL,
            forumName: "Example Blog",
            topic: wpTopic,
            state: .topic
        )
        app.browser.setPageContext(wpContext)
        app.browser.onPageContextChanged?(wpContext)

        XCTAssertEqual(app.assistantRequest, 1, "WordPress slug permalink share never opened the Assistant.")
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertTrue(
            app.activities.contains { $0.type == .summary && $0.topicKey == "blog.example.com/t/1001" },
            "WordPress slug permalink share never started the summary."
        )

        // iPad panel link drop (`app.openShared(url:action:"summary")`) on another WordPress slug post.
        let droppedURL = URL(string: "https://blog.example.com/2026/05/second-post/")!
        app.openShared(url: droppedURL, action: "summary")
        let secondTopic = ForumTopic(siteURL: wpSiteURL, topicID: "1002", url: droppedURL, title: "Second Post")
        let secondContext = PageContext(
            url: droppedURL,
            site: .wordpress,
            siteURL: wpSiteURL,
            forumName: "Example Blog",
            topic: secondTopic,
            state: .topic
        )
        app.browser.setPageContext(secondContext)
        app.browser.onPageContextChanged?(secondContext)

        XCTAssertEqual(app.assistantRequest, 2, "WordPress slug link drop never opened the Assistant.")
        XCTAssertTrue(
            app.activities.contains { $0.type == .summary && $0.topicKey == "blog.example.com/t/1002" },
            "WordPress slug link drop never started the summary."
        )
    }

    private let topicURL = URL(string: "https://forum.example.com/t/topic/42")!

    @MainActor
    private func makeReadyApp() -> AppModel {
        let app = AppModel(
            store: PersistentStore(
                fileURL: inboxDirectory.appendingPathComponent("state.json")
            )
        )
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        app.selectModel(ModelSelection(provider: .ollama, model: "llama3.2"), for: .both)
        XCTAssertTrue(app.isProviderReady)
        return app
    }

    /// What the browser reports once the shared topic has loaded.
    @MainActor
    private func deliverTopicPage(to app: AppModel) {
        let siteURL = "https://forum.example.com"
        let topic = ForumTopic(siteURL: siteURL, topicID: "42", url: topicURL, title: "Topic")
        let context = PageContext(
                url: topicURL,
                site: .discourse,
                siteURL: siteURL,
                forumName: "Example",
                topic: topic,
                state: .topic
        )
        app.browser.setPageContext(context)
        app.browser.onPageContextChanged?(context)
    }

    private func makeRequest(
        createdAt: Date,
        action: IncomingLinkRequest.Action = .open
    ) -> IncomingLinkRequest {
        IncomingLinkRequest(
            url: URL(string: "https://forum.example.com/t/topic/\(Int.random(in: 1...9999))")!,
            action: action,
            title: "Topic",
            createdAt: createdAt
        )
    }
}

/// A tap on a notification delivers its route and finishes on the main thread:
/// UIKit aborts if the system's completion handler runs anywhere else.
final class NotificationTapTests: XCTestCase {
    func testTappingAWatchedTopicNotificationFinishesOnTheMainThread() {
        let url = URL(string: "https://forum.example.com/t/topic/42")!
        let delivered = expectation(forNotification: WatchNotifier.openURLNotification, object: nil) {
            $0.object as? URL == url
        }
        let finished = expectation(description: "completion handler")
        DispatchQueue.global().async {
            WatchNotifier.open(userInfo: [WatchNotifier.urlKey: url.absoluteString]) {
                XCTAssertTrue(Thread.isMainThread)
                finished.fulfill()
            }
        }
        wait(for: [delivered, finished], timeout: 5)
    }
}
