import BackgroundTasks
import Foundation
import UserNotifications

/// Local notifications for watched topics, the daily digest, and the Agent's `notify` tool.
/// Tapping a watched topic's opens it in the embedded browser via `openURLNotification`;
/// the digest's opens the Today page (`openTodayNotification`).
final class WatchNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    struct NotificationBackend: Sendable {
        var authorizationStatus: @Sendable () async -> UNAuthorizationStatus
        var requestAuthorization: @Sendable () async throws -> Bool
        var add: @Sendable (UNNotificationRequest) async throws -> Void

        static let system = NotificationBackend(
            authorizationStatus: {
                guard !AppModel.isRunningTests else { return .denied }
                return (await UNUserNotificationCenter.current().notificationSettings()).authorizationStatus
            },
            requestAuthorization: {
                guard !AppModel.isRunningTests else { return false }
                return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            },
            add: { request in
                guard !AppModel.isRunningTests else { return }
                try await UNUserNotificationCenter.current().add(request)
            }
        )
    }

    enum NotifyError: LocalizedError, Equatable {
        case permissionDenied
        var errorDescription: String? {
            String(localized: "Notifications are turned off for WukongMind. Turn them on in Settings to receive alerts.")
        }
    }

    static let shared = WatchNotifier()
    static let openURLNotification = Notification.Name(AppIdentity.identifier("openURL"))
    static let openTodayNotification = Notification.Name(AppIdentity.identifier("openToday"))
    static let urlKey = "url"
    private static let routeKey = "route"
    private static let todayRoute = "today"
    /// A digest notification was tapped before the app model observed it
    /// (cold launch); the model opens the Today page when it's ready.
    @MainActor static var pendingTodayOpen = false
    let backend: NotificationBackend

    init(backend: NotificationBackend = .system) {
        self.backend = backend
        super.init()
    }

    func isAuthorized() async -> Bool {
        let status = await backend.authorizationStatus()
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func requestAuthorization() async -> Bool { (try? await backend.requestAuthorization()) ?? false }

    func notify(title: String, body: String) async throws {
        switch await backend.authorizationStatus() {
        case .notDetermined: guard await requestAuthorization() else { throw NotifyError.permissionDenied }
        case .authorized, .provisional, .ephemeral: break
        default: throw NotifyError.permissionDenied
        }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try await backend.add(UNNotificationRequest(identifier: "agent-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func notifyNewReplies(topic: WatchedTopic, count: Int) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = topic.title
        content.body = String(
            localized: "\(count) new replies in a watched topic.",
            comment: "Notification body; the title is the topic's title"
        )
        content.sound = .default
        content.userInfo = [Self.urlKey: topic.url.absoluteString]
        content.threadIdentifier = topic.topicKey
        let request = UNNotificationRequest(
            identifier: "watch-\(topic.topicKey)",
            content: content,
            trigger: nil
        )
        try? await backend.add(request)
    }

    /// "Today's digest is ready to make": the forum data is fetched, the
    /// summaries are made when the app opens (never claims they are ready).
    func notifyDigestReady(topicCount: Int) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Today’s digest is ready to make", comment: "Notification title after the daily digest's forum data was fetched in the background; the AI summaries are made when the app opens")
        content.body = String(
            localized: "\(topicCount) topics are waiting. Open WukongMind to summarize them.",
            comment: "Digest notification body; the number is how many topics the digest will have"
        )
        content.sound = .default
        content.userInfo = [Self.routeKey: Self.todayRoute]
        content.threadIdentifier = "digest"
        let request = UNNotificationRequest(identifier: "digest-ready", content: content, trigger: nil)
        try? await backend.add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Not the `async` form: its generated thunk calls the system's completion
    // handler off the main thread, and UIKit aborts on that.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Self.open(userInfo: response.notification.request.content.userInfo, then: completionHandler)
    }

    /// Routes a tapped notification, then calls `done` on the main thread.
    static func open(userInfo: [AnyHashable: Any], then done: @escaping () -> Void) {
        let route = userInfo[routeKey] as? String
        let url = (userInfo[urlKey] as? String).flatMap(URL.init(string:))
        Task { @MainActor in
            if route == todayRoute {
                pendingTodayOpen = true
                NotificationCenter.default.post(name: openTodayNotification, object: nil)
            } else if let url {
                NotificationCenter.default.post(name: openURLNotification, object: url)
            }
            done()
        }
    }
}

/// System-scheduled background refresh of watched topics (best effort; iOS
/// decides when it runs). Registration must happen before launch finishes.
enum WatchBackgroundRefresh {
    /// Matches `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let identifier = AppIdentity.identifier("watchRefresh")
    static var perform: (() async -> Void)?
    private static let minimumInterval: TimeInterval = 30 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        // Submitting fails on the simulator and when Background App Refresh is
        // off; foreground checks still cover those cases.
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        schedule()
        let work = Task {
            await perform?()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
