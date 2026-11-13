import Combine
import Foundation

// How far along a running job is. Summaries report fetch pages, batch sizes
// and streamed text into a clock-driven tracker; the agent reports steps
// against its budget; chat is indeterminate once the model is asked.
// Everything in the tracker is pure so the mapping can be tested.

/// One step of a summary, reported as it happens.
enum SummaryProgressEvent: Equatable, Sendable {
    case fetched(completedPages: Int, totalPages: Int)
    case batchesPlanned(level: Int, sizes: [Int])
    /// Batch `index` (0-based) of `count` at fold `level` (1 = sections, 2+ = folds).
    case batchStarted(level: Int, index: Int, count: Int)
    case batchFinished(level: Int, index: Int, count: Int)
    /// Single pass (`!combining`) or final pass over batch summaries (`combining`).
    case finalStarted(combining: Bool)
    case streamed(characters: Int)
    case finished
}

/// Maps fetch progress, summary events and elapsed time to a single 0…1 bar.
/// Monotonic, below 1 until `.finished`, then 1.
struct SummaryProgressTracker: Equatable {
    static let sectionsEnd = 0.72
    static let foldsEnd = 0.80
    static let ceiling = 0.99

    private(set) var fraction = 0.0
    private(set) var statusText: String?
    var inputCharacters: Int
    private var baselinePages: Int
    private var fetchEnd = 0.0
    private var previousSummaryCharacters: Int?
    private var levelWeights: [Int: [Double]] = [:]
    private var stepStart = 0.0, stepEnd = 0.08, stepStartedAt = 0.0, stepExpected = 3_200.0
    private var streamedCharacters = 0
    private var lastElapsed: TimeInterval = 0
    private var isFinished = false

    init(cachedPages: Int = 0, inputCharacters: Int = 0, previousSummaryCharacters: Int? = nil) {
        baselinePages = max(0, cachedPages)
        self.inputCharacters = max(0, inputCharacters)
        self.previousSummaryCharacters = previousSummaryCharacters
    }

    /// 0 when nothing is fetched; otherwise grows smoothly with pages to fetch.
    static func fetchShare(pagesToFetch: Int) -> Double {
        pagesToFetch > 0 ? min(0.8, Double(pagesToFetch) / Double(pagesToFetch + 15)) : 0
    }

    /// Previous summary length on a refresh, else scaled from input size.
    static func expectedOutput(input: Int, previous: Int?, cap: Double) -> Double {
        if let previous, previous > 0 { return max(200, Double(previous)) }
        return min(cap, max(300, 180 + Double(max(0, input)) * 0.15))
    }

    /// Level 1 takes the sections range; each later fold takes half of what remains.
    static func range(level: Int) -> ClosedRange<Double> {
        guard level > 1 else { return 0...sectionsEnd }
        let span = foldsEnd - sectionsEnd
        let start = sectionsEnd + span * (1 - pow(0.5, Double(level - 2)))
        let end = sectionsEnd + span * (1 - pow(0.5, Double(level - 1)))
        return start...end
    }

    @discardableResult
    mutating func tick(elapsed: TimeInterval) -> Double {
        guard !isFinished else { return fraction }
        let now = max(lastElapsed, elapsed)
        return advance(to: stepPosition(at: now), at: now)
    }

    @discardableResult
    mutating func apply(_ event: SummaryProgressEvent, elapsed: TimeInterval = 0) -> Double {
        guard !isFinished else { return 1 }
        let now = max(lastElapsed, elapsed)
        switch event {
        case let .fetched(completedPages, totalPages):
            baselinePages = min(baselinePages, max(0, completedPages))
            let pages = max(0, totalPages - baselinePages)
            fetchEnd = Self.fetchShare(pagesToFetch: pages)
            let done = min(pages, max(0, completedPages - baselinePages))
            let start = pages > 0 ? fetchEnd * Double(done) / Double(pages) : 0
            let end = pages > 0 ? fetchEnd * Double(min(pages, done + 1)) / Double(pages) : 0
            beginStep(start: start, end: end, expected: stepExpected, at: now)
            return advance(to: start, at: now)
        case let .batchesPlanned(level, sizes):
            levelWeights[level] = sizes.map { Double(max(1, $0)) }
            if level == 1, inputCharacters == 0 { inputCharacters = sizes.reduce(0) { $0 + max(0, $1) } }
            return advance(to: fraction, at: now)
        case let .batchStarted(level, index, count):
            let bounds = batchBounds(level: level, index: index, count: count)
            let batchInput = levelWeights[level]
                .flatMap { $0.count == count && $0.indices.contains(index) ? Int($0[index]) : nil }
                ?? max(1, inputCharacters / max(count, 1))
            beginStep(start: bounds.lowerBound, end: bounds.upperBound,
                      expected: Self.expectedOutput(input: batchInput, previous: nil, cap: 1_800), at: now)
            statusText = level == 1
                ? String(localized: "Summarizing part \(index + 1) of \(count)…", comment: "Progress of a long summary: the discussion is summarized in parts")
                : String(localized: "Condensing part \(index + 1) of \(count)…", comment: "Progress of a long summary: the part summaries are shortened again")
            return advance(to: bounds.lowerBound, at: now)
        case let .batchFinished(level, index, count):
            let end = batchBounds(level: level, index: index, count: count).upperBound
            beginStep(start: end, end: end, expected: stepExpected, at: now)
            return advance(to: end, at: now)
        case let .finalStarted(combining):
            let start = aiPoint(combining ? Self.foldsEnd : 0)
            beginStep(start: start, end: Self.ceiling,
                      expected: Self.expectedOutput(input: inputCharacters, previous: previousSummaryCharacters, cap: 3_200), at: now)
            statusText = combining ? String(localized: "Combining…", comment: "Progress of a long summary: the part summaries are merged into the final summary") : nil
            return advance(to: start, at: now)
        case let .streamed(characters):
            streamedCharacters = max(streamedCharacters, max(0, characters))
            return advance(to: stepPosition(at: now), at: now)
        case .finished:
            isFinished = true
            lastElapsed = now
            fraction = 1
            return 1
        }
    }

    private func aiPoint(_ aiFraction: Double) -> Double { fetchEnd + (1 - fetchEnd) * aiFraction }

    private func batchBounds(level: Int, index: Int, count: Int) -> ClosedRange<Double> {
        let range = Self.range(level: level)
        let safeCount = max(count, 1)
        let weights = levelWeights[level].flatMap { $0.count == safeCount ? $0 : nil }
            ?? Array(repeating: 1.0, count: safeCount)
        let total = weights.reduce(0, +)
        let clamped = min(max(index, 0), safeCount - 1)
        let span = range.upperBound - range.lowerBound
        let start = range.lowerBound + span * weights.prefix(clamped).reduce(0, +) / total
        let end = range.lowerBound + span * weights.prefix(clamped + 1).reduce(0, +) / total
        return aiPoint(start)...aiPoint(end)
    }

    private mutating func beginStep(start: Double, end: Double, expected: Double, at now: TimeInterval) {
        stepStart = start
        stepEnd = max(start, end)
        stepStartedAt = now
        stepExpected = expected
        streamedCharacters = 0
    }

    private func stepPosition(at now: TimeInterval) -> Double {
        let waited = max(0, now - stepStartedAt)
        let ratio = stepExpected > 0 ? Double(streamedCharacters) / stepExpected : 0
        let effort = waited * 0.12 + ratio * 3
        return stepStart + (stepEnd - stepStart) * 0.98 * (1 - 1 / (1 + effort))
    }

    private mutating func advance(to candidate: Double, at now: TimeInterval) -> Double {
        lastElapsed = now
        let cap = min(max(fraction, stepEnd), Self.ceiling)
        fraction = max(fraction, min(candidate, cap))
        return fraction
    }
}

/// Where a topic's summary stands, from its newest summary job: the drawer
/// shows progress while it runs and the error with Retry when it failed. A
/// newer run (Retry, a watched refresh) replaces an older failure; cancelled
/// or finished jobs leave nothing to show.
enum SummaryRunState: Equatable {
    case idle
    case running
    case failed(message: String)

    static func resolve(_ records: [WorkRecord], topicKey: String) -> SummaryRunState {
        let newest = records
            .filter { $0.type == .summary && $0.topicKey == topicKey }
            .max { $0.createdAt < $1.createdAt }
        switch newest?.status {
        case .queued?, .running?: return .running
        case .failed?: return .failed(message: newest?.error ?? "")
        case .completed?, .cancelled?, nil: return .idle
        }
    }
}

/// Maps each work type's phases onto a running job's single 0…1 progress.
enum WorkProgress {
    /// The share of the bar the forum fetch fills while the job runs.
    static func fetchShare(for type: WorkType) -> Double {
        switch type {
        case .pull: SummaryProgressTracker.ceiling
        case .summary, .agent: 0
        // Chat goes indeterminate once the model is asked; the fetch never
        // claims more than a third of the bar.
        case .chat: 0.3
        }
    }

    static func fetch(_ fraction: Double, type: WorkType) -> Double {
        min(max(fraction, 0), 1) * fetchShare(for: type)
    }

    /// The agent's progress: `completedSteps` of a budget of `maxSteps` (plus
    /// the final answer), with `within` (0…1) of the current step done.
    static func agent(completedSteps: Int, maxSteps: Int, within: Double = 0) -> Double {
        let total = Double(max(maxSteps, 0) + 1)
        let done = Double(max(completedSteps, 0)) + min(max(within, 0), 0.95)
        return min(done / total, SummaryProgressTracker.ceiling)
    }

    /// Where a new value lands: determinate progress only moves forward within
    /// a run; nil (indeterminate) is always allowed.
    static func advanced(from current: Double?, to next: Double?) -> Double? {
        guard let next else { return nil }
        return max(current ?? 0, min(max(next, 0), 1))
    }
}

/// Live 0…1 progress of running work, by `WorkRecord.id`. Kept out of
/// `AppModel` (beside `StreamStore`) so streaming progress ticks only redraw
/// the views that draw a progress bar, ring or percentage.
///
/// Absence (`nil`) means indeterminate (queued work, or a chat answer once
/// the model is asked). Determinate values only move forward within a run,
/// and clear when the job finishes, fails, is cancelled, or pauses.
@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var values: [UUID: Double] = [:]

    var isEmpty: Bool { values.isEmpty }

    func value(for id: UUID) -> Double? {
        values[id]
    }

    /// Moves a job's determinate progress forward (never back), or clears it
    /// to indeterminate (`nil`). Unchanged values do not publish.
    func advance(_ id: UUID, to fraction: Double?) {
        let next = WorkProgress.advanced(from: values[id], to: fraction)
        guard next != values[id] else { return }
        values[id] = next
    }

    /// Sets a job's progress at once (fixtures, debug samples).
    func set(_ fraction: Double?, for id: UUID) {
        let next = fraction.map { min(max($0, 0), 1) }
        guard next != values[id] else { return }
        values[id] = next
    }

    func remove(_ id: UUID) {
        guard values[id] != nil else { return }
        values.removeValue(forKey: id)
    }
}

/// Rate limit for progress writes (they redraw the views showing the bar):
/// at most one per `interval`; later values wait for the next slot.
struct ProgressThrottle: Equatable {
    var interval: TimeInterval = 0.1
    private(set) var lastEmit: Date?

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    /// nil: write now (and the write is recorded). Otherwise, how long to
    /// wait before the next write is allowed.
    mutating func delay(at now: Date, force: Bool = false) -> TimeInterval? {
        if force || lastEmit.map({ now.timeIntervalSince($0) >= interval }) ?? true {
            lastEmit = now
            return nil
        }
        return interval - now.timeIntervalSince(lastEmit ?? now)
    }
}

/// Coalesces a job's progress reports into throttled writes; the latest value
/// is always written once its slot comes. `cancel()` drops a pending write
/// (the job ended).
@MainActor
final class ThrottledProgress {
    typealias Write = @MainActor (_ fraction: Double?, _ statusText: String?) -> Void

    private var throttle: ProgressThrottle
    private let write: Write
    private let now: () -> Date
    private var pendingFraction: Double?
    private var pendingStatus: String?
    private var hasPending = false
    private var flushTask: Task<Void, Never>?
    private var cancelled = false

    init(interval: TimeInterval = 0.1, now: @escaping () -> Date = Date.init, write: @escaping Write) {
        throttle = ProgressThrottle(interval: interval)
        self.now = now
        self.write = write
    }

    /// A new status text is written right away (it changes once per step);
    /// fraction-only updates are rate limited unless `force` is set.
    func report(_ fraction: Double?, statusText: String? = nil, force: Bool = false) {
        guard !cancelled else { return }
        pendingFraction = fraction
        if let statusText { pendingStatus = statusText }
        hasPending = true
        if let wait = throttle.delay(at: now(), force: force || statusText != nil) {
            guard flushTask == nil else { return }
            flushTask = Task { @MainActor [weak self] in
                // Cancelled: a forced write already went out (or the job ended).
                guard (try? await Task.sleep(for: .seconds(wait))) != nil, !Task.isCancelled else { return }
                self?.flushTask = nil
                self?.flush()
            }
        } else {
            flushTask?.cancel()
            flushTask = nil
            emit()
        }
    }

    /// Writes any pending value now.
    func flush() {
        guard !cancelled, hasPending else { return }
        _ = throttle.delay(at: now(), force: true)
        emit()
    }

    func cancel() {
        cancelled = true
        hasPending = false
        flushTask?.cancel()
        flushTask = nil
    }

    private func emit() {
        let fraction = pendingFraction
        let status = pendingStatus
        hasPending = false
        pendingStatus = nil
        write(fraction, status)
    }
}

/// Feeds a summary's events and periodic wait ticks through a tracker into
/// throttled progress writes; `map` places the fraction on the job's bar.
@MainActor
final class SummaryProgressFeed {
    private(set) var tracker: SummaryProgressTracker
    private let output: ThrottledProgress
    private let map: (Double) -> Double
    private let now: () -> Date
    private let startedAt: Date
    nonisolated(unsafe) private var tickTask: Task<Void, Never>?
    private(set) var isStopped = false

    init(
        tracker: SummaryProgressTracker = SummaryProgressTracker(),
        output: ThrottledProgress,
        now: @escaping () -> Date = Date.init,
        tickInterval: Duration? = .milliseconds(250),
        map: @escaping (Double) -> Double = { $0 }
    ) {
        self.tracker = tracker
        self.output = output
        self.now = now
        startedAt = now()
        self.map = map
        if let tickInterval {
            tickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard (try? await Task.sleep(for: tickInterval)) != nil, !Task.isCancelled else { return }
                    self?.tick()
                }
            }
        }
    }

    deinit { tickTask?.cancel() }

    private var elapsed: TimeInterval { max(0, now().timeIntervalSince(startedAt)) }

    func setInputCharacters(_ characters: Int) {
        guard !isStopped else { return }
        tracker.inputCharacters = max(0, characters)
    }

    func handle(_ event: SummaryProgressEvent) {
        guard !isStopped else { return }
        if event == .finished { finish(); return }
        let previousStatus = tracker.statusText
        tracker.apply(event, elapsed: elapsed)
        let status = tracker.statusText != previousStatus ? tracker.statusText : nil
        let isStepStart = if case .batchStarted = event { true } else if case .finalStarted = event { true } else { false }
        output.report(map(tracker.fraction), statusText: status, force: isStepStart || status != nil)
    }

    func tick() {
        guard !isStopped else { return }
        let previous = tracker.fraction
        let next = tracker.tick(elapsed: elapsed)
        if next > previous { output.report(map(next), statusText: nil) }
    }

    func finish() {
        guard !isStopped else { return }
        tracker.apply(.finished, elapsed: elapsed)
        output.report(map(tracker.fraction), statusText: nil, force: true)
        cancel()
    }

    func cancel() {
        isStopped = true
        tickTask?.cancel()
        tickTask = nil
        output.cancel()
    }
}
