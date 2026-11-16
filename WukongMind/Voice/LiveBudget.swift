import Foundation

/// The cost cap on live Gemini Live connections in tests and spikes
/// (docs/DEVELOPMENT.md "Live Gemini Live budget"). Every
/// `WebSocketLiveTransport` asks it before opening, so unit tests, the
/// spike and an app launched by a UI test all go through it.
///
/// It is active only in a test process (XCTest loaded) or when
/// `GEMINI_LIVE_BUDGET` is set; the app in normal use has no cap here
/// (its own guard is the voice minutes in Settings).
///
/// `GEMINI_LIVE_BUDGET` is "sessions,seconds" (e.g. "3,120"); the default
/// in a test process is `defaultCap`. Past the cap a connection is refused
/// at once with a 1008 close, and an open one is closed when the seconds
/// run out. Each connection logs a `[LIVE-BUDGET]` line with what it used.
@MainActor
final class LiveBudget {
    struct Cap: Equatable {
        var sessions: Int
        var seconds: TimeInterval
    }

    struct Lease {
        let number: Int
        let label: String
        let openedAt: Date
    }

    static let environmentKey = "GEMINI_LIVE_BUDGET"
    static let defaultCap = Cap(sessions: 3, seconds: 120)
    static let refusalPrefix = "Live test budget"

    /// The process's budget; nil when no cap applies.
    static let shared: LiveBudget? = configuredCap(environment: ProcessInfo.processInfo.environment).map { LiveBudget(cap: $0) }

    /// The cap for this environment: `GEMINI_LIVE_BUDGET` if set, the default
    /// in a test process, else nil.
    nonisolated static func configuredCap(environment: [String: String]) -> Cap? {
        if let text = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            return parse(text) ?? defaultCap
        }
        let isTest = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
        return isTest ? defaultCap : nil
    }

    /// "3,120" → 3 sessions, 120 s.
    nonisolated static func parse(_ text: String) -> Cap? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let sessions = Int(parts[0]), let seconds = Double(parts[1]), sessions >= 0, seconds >= 0 else {
            return nil
        }
        return Cap(sessions: sessions, seconds: seconds)
    }

    let cap: Cap
    private(set) var sessionsUsed = 0
    private(set) var secondsUsed: TimeInterval = 0
    private var open: [Int: Date] = [:]
    private let now: () -> Date

    init(cap: Cap, now: @escaping () -> Date = Date.init) {
        self.cap = cap
        self.now = now
    }

    /// Seconds left for open connections, counting the ones still open.
    func remainingSeconds() -> TimeInterval {
        let running = open.values.reduce(0) { $0 + now().timeIntervalSince($1) }
        return max(0, cap.seconds - secondsUsed - running)
    }

    /// Charges one session, or refuses when the cap is used up.
    func begin(_ label: String) throws -> Lease {
        guard sessionsUsed < cap.sessions, remainingSeconds() > 0 else {
            let reason = "\(Self.refusalPrefix) used up: \(sessionsUsed) of \(cap.sessions) sessions, "
                + "\(Self.format(secondsUsed)) of \(Self.format(cap.seconds)) s (set \(Self.environmentKey) to raise it)"
            print("[LIVE-BUDGET] refused \(label): \(reason)")
            throw LiveClose(code: LiveClose.policyViolation, reason: reason)
        }
        sessionsUsed += 1
        let openedAt = now()
        print("[LIVE-BUDGET] session \(sessionsUsed)/\(cap.sessions) opened (\(label)); \(Self.format(remainingSeconds())) s left")
        open[sessionsUsed] = openedAt
        return Lease(number: sessionsUsed, label: label, openedAt: openedAt)
    }

    /// The connection closed: adds its seconds.
    func end(_ lease: Lease) {
        guard open.removeValue(forKey: lease.number) != nil else { return }
        let seconds = max(0, now().timeIntervalSince(lease.openedAt))
        secondsUsed += seconds
        print("[LIVE-BUDGET] session \(lease.number)/\(cap.sessions) closed (\(lease.label)) after \(Self.format(seconds)) s; "
            + "\(Self.format(secondsUsed)) of \(Self.format(cap.seconds)) s used this run")
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds)
    }
}
