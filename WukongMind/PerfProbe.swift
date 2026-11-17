import Foundation
import os

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
    }

    static func time<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let interval = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            signposter.endInterval(name, interval)
            let key = "\(name)"
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
    @inline(__always) static func time<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T { try body() }
    #endif
}
