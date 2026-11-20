import Foundation
import os
#if DEBUG
import Combine
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

/// Counts and times the drawer's hot paths (docs/wukongmind/design-performance-and-state.md).
///
/// DEBUG only: in Release every call is an inlined no-op, and in Debug it does nothing
/// until `isEnabled` is set (the `-dc-perf-probe` launch argument, or a test). `hit` counts
/// a view body evaluation, `time` adds the wall time of a block; both also emit signposts
/// (subsystem `io.github.kccarlos.wukongmind.perf`) so Instruments shows them on a
/// device. `DrawerPerformanceTests` reads the numbers; nothing in the app does.
enum PerfProbe {
    #if DEBUG
    struct Snapshot: Equatable {
        var counts: [String: Int] = [:]
        var seconds: [String: Double] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private static let signposter = OSSignposter(subsystem: "io.github.kccarlos.wukongmind.perf", category: "drawer")

    /// Off by default so an ordinary Debug run does no extra work in its view bodies.
    nonisolated(unsafe) static var isEnabled = ProcessInfo.processInfo.arguments.contains("-dc-perf-probe")

    static func hit(_ name: StaticString) {
        guard isEnabled else { return }
        signposter.emitEvent(name)
        let key = "\(name)"
        state.withLock { $0.counts[key, default: 0] += 1 }
        PerfTimeline.hit(key)
    }

    /// A named moment in the timeline of the current touch (`PerfTimeline`).
    static func mark(_ name: @autoclosure () -> String) {
        guard isEnabled else { return }
        PerfTimeline.mark(name())
    }

    static func time<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let interval = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            signposter.endInterval(name, interval)
            let key = "\(name)"
            PerfTimeline.span(key, start: Double(start) / 1_000_000_000, seconds: elapsed)
            state.withLock {
                $0.counts[key, default: 0] += 1
                $0.seconds[key, default: 0] += elapsed
            }
        }
        return try body()
    }

    static func reset() {
        state.withLock { $0 = Snapshot() }
    }

    static var snapshot: Snapshot {
        state.withLock { $0 }
    }

    // MARK: Main-thread monitor (`-dc-perf-probe`)

    /// How long each main run loop pass worked before it slept again, as cumulative
    /// buckets: a reader takes two reports and subtracts (`PerfProbeState`).
    struct MainThreadReport: Equatable {
        static let thresholds: [Double] = [0.0167, 0.033, 0.05, 0.1, 0.25, 0.5, 1]
        var passes = 0
        var busySeconds: Double = 0
        var over = [Int](repeating: 0, count: thresholds.count)
    }

    private static let mainThread = OSAllocatedUnfairLock(initialState: MainThreadReport())
    private static var monitorObservers: [CFRunLoopObserver] = []
    private static var passStartedAt: UInt64?

    static var mainThreadReport: MainThreadReport {
        mainThread.withLock { $0 }
    }

    /// Starts once; the wake is seen first and the sleep last, so Core Animation's
    /// commit (where SwiftUI updates and lays out) is inside the pass.
    @MainActor
    static func startMainThreadMonitor() {
        guard monitorObservers.isEmpty else { return }
        let wake: CFRunLoopActivity = [.entry, .afterWaiting]
        let sleep: CFRunLoopActivity = [.beforeWaiting, .exit]
        monitorObservers = [
            CFRunLoopObserverCreateWithHandler(nil, wake.rawValue, true, CFIndex.min) { _, _ in
                if passStartedAt == nil { passStartedAt = DispatchTime.now().uptimeNanoseconds }
            },
            CFRunLoopObserverCreateWithHandler(nil, sleep.rawValue, true, CFIndex.max) { _, _ in
                guard let start = passStartedAt else { return }
                passStartedAt = nil
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                PerfTimeline.pass(start: Double(start) / 1_000_000_000, seconds: seconds)
                mainThread.withLock { report in
                    report.passes += 1
                    report.busySeconds += seconds
                    for (index, threshold) in MainThreadReport.thresholds.enumerated() where seconds > threshold {
                        report.over[index] += 1
                    }
                }
            }
        ].compactMap { $0 }
        monitorObservers.forEach { CFRunLoopAddObserver(CFRunLoopGetMain(), $0, .commonModes) }
    }
    #else
    @inline(__always) static func hit(_ name: StaticString) {}
    @inline(__always) static func mark(_ name: @autoclosure () -> String) {}
    @inline(__always) static func time<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T { try body() }
    #endif
}

#if DEBUG
/// What the main thread did after one touch (docs/wukongmind/design-performance-2.md), with `-dc-perf-probe`.
///
/// A window opens at a touch down and closes 3 s after the touch up. In it: the touch's own
/// times (when the screen was touched, when the app was told), `PerfProbe.mark` moments, the first
/// and last `PerfProbe.hit` of each name, `PerfProbe.time` spans, every main run loop pass of 8 ms
/// or more, display-link gaps over 34 ms, and the first display-link tick after each mark. All in
/// milliseconds from the touch down. The closed window is the `perfTimeline` accessibility
/// element's label; a UI test taps, waits without asking the app anything, then reads it.
/// Main thread only; measurement only.
enum PerfTimeline {
    final class Store: ObservableObject {
        @Published var text = ""
    }

    @MainActor static let store = Store()
    nonisolated(unsafe) private static var origin: Double?
    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var windows = 0
    nonisolated(unsafe) private static var marks: [(name: String, at: Double)] = []
    nonisolated(unsafe) private static var hits: [String: (first: Double, last: Double, count: Int)] = [:]
    nonisolated(unsafe) private static var hitOrder: [String] = []
    nonisolated(unsafe) private static var spans: [(name: String, at: Double, seconds: Double)] = []
    nonisolated(unsafe) private static var passes: [(at: Double, seconds: Double)] = []
    nonisolated(unsafe) private static var gaps: [(at: Double, seconds: Double)] = []
    nonisolated(unsafe) private static var awaitingFrame: [String] = []
    nonisolated(unsafe) private static var frames: [(name: String, at: Double)] = []
    nonisolated(unsafe) private static var lastTick: Double?
    nonisolated(unsafe) private static var link: CADisplayLink?
    nonisolated(unsafe) private static var ticker: Ticker?
    nonisolated(unsafe) private static var windowObserver: NSObjectProtocol?

    private static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private static var recording: Bool { origin != nil && Thread.isMainThread }

    /// Watches touches in every window, and starts the main-thread monitor.
    @MainActor
    static func install() {
        guard PerfProbe.isEnabled, windowObserver == nil else { return }
        PerfProbe.startMainThreadMonitor()
        let attach: (UIWindow) -> Void = { window in
            guard !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchWatcher }) else { return }
            window.addGestureRecognizer(TouchWatcher())
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(attach)
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { attach(window) }
        }
    }

    /// A touch went down at `timestamp` (the event's own time): a new window.
    @MainActor
    fileprivate static func touchDown(at timestamp: Double) {
        generation += 1
        origin = timestamp
        marks = [("down.delivered", now)]
        hits = [:]; hitOrder = []; spans = []; passes = []; gaps = []; awaitingFrame = []; frames = []
        lastTick = nil
        if link == nil {
            let ticker = Ticker()
            let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
            link.add(to: .main, forMode: .common)
            self.ticker = ticker
            self.link = link
        }
    }

    @MainActor
    fileprivate static func touchUp(at timestamp: Double) {
        guard origin != nil else { return }
        marks.append(("up", timestamp))
        marks.append(("up.delivered", now))
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard token == generation else { return }
            close()
        }
    }

    static func mark(_ name: String) {
        guard recording else { return }
        marks.append((name, now))
        awaitingFrame.append(name)
    }

    static func hit(_ name: String) {
        guard recording else { return }
        let at = now
        if let seen = hits[name] {
            hits[name] = (seen.first, at, seen.count + 1)
        } else {
            hits[name] = (at, at, 1)
            hitOrder.append(name)
        }
    }

    static func span(_ name: String, start: Double, seconds: Double) {
        guard recording else { return }
        spans.append((name, start, seconds))
    }

    static func pass(start: Double, seconds: Double) {
        guard recording, seconds >= 0.008 else { return }
        passes.append((start, seconds))
    }

    fileprivate static func tick() {
        guard recording else { return }
        let at = now
        if let last = lastTick, at - last > 0.034 { gaps.append((last, at - last)) }
        lastTick = at
        if !awaitingFrame.isEmpty {
            frames += awaitingFrame.map { ($0, at) }
            awaitingFrame = []
        }
    }

    @MainActor
    private static func close() {
        guard let origin else { return }
        func ms(_ at: Double) -> Int { Int(((at - origin) * 1_000).rounded()) }
        func dur(_ seconds: Double) -> Int { Int((seconds * 1_000).rounded()) }
        windows += 1
        var fields = ["n=\(windows)"]
        fields += marks.map { "m:\($0.name)=\(ms($0.at))" }
        fields += frames.map { "f:\($0.name)=\(ms($0.at))" }
        fields += hitOrder.compactMap { name in hits[name].map { "h:\(name)=\(ms($0.first))/\(ms($0.last))x\($0.count)" } }
        fields += spans.map { "s:\($0.name)=\(ms($0.at))+\(dur($0.seconds))" }
        fields += passes.map { "p:\(ms($0.at))+\(dur($0.seconds))" }
        fields += gaps.map { "g:\(ms($0.at))+\(dur($0.seconds))" }
        fields.append("busy_ms=\(dur(passes.reduce(0) { $0 + $1.seconds }))")
        self.origin = nil
        link?.invalidate()
        link = nil
        ticker = nil
        store.text = fields.joined(separator: " ")
    }

    private final class Ticker: NSObject {
        @objc func tick() { PerfTimeline.tick() }
    }

    /// Sees every touch and claims none.
    private final class TouchWatcher: UIGestureRecognizer {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { PerfTimeline.touchDown(at: touch.timestamp) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { PerfTimeline.touchUp(at: touch.timestamp) }
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { PerfTimeline.touchUp(at: touch.timestamp) }
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

/// `-dc-perf-probe`: the last closed `PerfTimeline` window as the `perfTimeline` accessibility element,
/// plus cumulative address-bar counts (`perfAddressProbeState`).
struct PerfTimelineState: View {
    @ObservedObject private var store = PerfTimeline.store
    @State private var addressState = ""
    private let ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private static func currentAddressState() -> String {
        let main = PerfProbe.mainThreadReport
        let probe = PerfProbe.snapshot
        var fields = [
            "passes=\(main.passes)",
            "busy_ms=\(Int(main.busySeconds * 1_000))"
        ]
        for (index, threshold) in PerfProbe.MainThreadReport.thresholds.enumerated() {
            fields.append("over\(Int(threshold * 1_000))=\(main.over[index])")
        }
        for name in ["HomeList.body", "AddressEditBar.body"] {
            fields.append("n:\(name)=\(probe.counts[name] ?? 0)")
        }
        for name in ["HomeSites.matches", "AddressInput.actions"] {
            fields.append("n:\(name)=\(probe.counts[name] ?? 0)")
            fields.append("us:\(name)=\(Int((probe.seconds[name] ?? 0) * 1_000_000))")
        }
        return fields.joined(separator: " ")
    }

    var body: some View {
        ZStack {
            Text(verbatim: "t")
                .font(.system(size: 2))
                .frame(width: 4, height: 4)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityLabel(Text(verbatim: store.text.isEmpty ? "n=0" : store.text))
                .accessibilityIdentifier("perfTimeline")
                .onAppear { PerfTimeline.install() }

            Text(verbatim: addressState)
                .font(.system(size: 2))
                .frame(width: 4, height: 4)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityLabel(Text(verbatim: addressState))
                .accessibilityIdentifier("perfAddressProbeState")
                .onAppear {
                    PerfProbe.startMainThreadMonitor()
                    addressState = Self.currentAddressState()
                }
                .onReceive(ticks) { _ in addressState = Self.currentAddressState() }
        }
    }
}
#endif
