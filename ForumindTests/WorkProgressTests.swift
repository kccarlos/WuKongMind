import Combine
import XCTest
@testable import Forumind

/// Progress of running work: the phase → fraction mapping, fake-clock
/// user scenarios, throttling, and the progress bar's clock-driven motion.
@MainActor
final class WorkProgressTests: XCTestCase {
    // MARK: Summary mapping

    func testHierarchicalSummaryProgressIsMonotonicAndCountsBatches() {
        var tracker = SummaryProgressTracker()
        var fractions: [Double] = []
        func apply(_ event: SummaryProgressEvent) { fractions.append(tracker.apply(event)) }

        for index in 0..<7 {
            apply(.batchStarted(level: 1, index: index, count: 7))
            if index == 2 { XCTAssertEqual(tracker.statusText, "Summarizing part 3 of 7…") }
            for characters in stride(from: 0, through: 4_000, by: 400) { apply(.streamed(characters: characters)) }
            apply(.batchFinished(level: 1, index: index, count: 7))
            XCTAssertEqual(tracker.fraction, SummaryProgressTracker.sectionsEnd * Double(index + 1) / 7, accuracy: 1e-9)
        }
        for index in 0..<2 {
            apply(.batchStarted(level: 2, index: index, count: 2))
            XCTAssertEqual(tracker.statusText, "Condensing part \(index + 1) of 2…")
            apply(.batchFinished(level: 2, index: index, count: 2))
        }
        apply(.finalStarted(combining: true))
        XCTAssertEqual(tracker.statusText, "Combining…")
        XCTAssertEqual(tracker.fraction, SummaryProgressTracker.foldsEnd, accuracy: 1e-9)
        for characters in stride(from: 0, through: 50_000, by: 500) { apply(.streamed(characters: characters)) }

        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
        XCTAssertLessThan(fractions.last ?? 1, 1, "only the finished run reports 100%")
        XCTAssertGreaterThan(fractions.last ?? 0, 0.95)
        XCTAssertEqual(tracker.apply(.finished), 1)
    }

    func testStreamingScalesWithExpectedLengthAndStaysWithinItsStep() {
        var short = SummaryProgressTracker(inputCharacters: 1_200)
        short.apply(.finalStarted(combining: false))
        XCTAssertNil(short.statusText, "a single pass keeps the caller's status")
        XCTAssertEqual(short.fraction, 0)

        var long = SummaryProgressTracker(inputCharacters: 18_000)
        long.apply(.finalStarted(combining: false))
        XCTAssertGreaterThan(
            short.apply(.streamed(characters: 300)),
            long.apply(.streamed(characters: 300)),
            "300 streamed characters is further along in a short topic than a long one"
        )

        var refresh = SummaryProgressTracker(inputCharacters: 18_000, previousSummaryCharacters: 500)
        refresh.apply(.finalStarted(combining: false))
        XCTAssertGreaterThan(
            refresh.apply(.streamed(characters: 300)),
            long.apply(.streamed(characters: 300)),
            "a refresh measures streamed text against the previous summary length"
        )

        let early = long.fraction
        let later = long.apply(.streamed(characters: 3_000))
        let overrun = long.apply(.streamed(characters: 100_000))
        XCTAssertGreaterThan(later, early)
        XCTAssertGreaterThan(overrun, later)
        XCTAssertLessThanOrEqual(overrun, SummaryProgressTracker.ceiling)

        // Streamed text moves within its batch only.
        var batches = SummaryProgressTracker()
        batches.apply(.batchStarted(level: 1, index: 0, count: 4))
        batches.apply(.streamed(characters: 1_000_000))
        XCTAssertLessThan(batches.fraction, SummaryProgressTracker.sectionsEnd / 4)
    }

    func testFoldLevelsShareTheirRangeAndARetryNeverGoesBack() {
        var previousEnd = SummaryProgressTracker.sectionsEnd
        for level in 2...6 {
            let range = SummaryProgressTracker.range(level: level)
            XCTAssertEqual(range.lowerBound, previousEnd, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(range.upperBound, SummaryProgressTracker.foldsEnd)
            previousEnd = range.upperBound
        }
        // Apple Intelligence retries in smaller sections: the new pass starts
        // over, the bar holds (and creeps on ticks) until it catches up.
        var tracker = SummaryProgressTracker()
        tracker.apply(.batchStarted(level: 1, index: 0, count: 2))
        tracker.apply(.batchFinished(level: 1, index: 0, count: 2))
        let reached = tracker.fraction
        tracker.apply(.batchStarted(level: 1, index: 0, count: 5))
        XCTAssertEqual(tracker.fraction, reached)
        tracker.apply(.batchFinished(level: 1, index: 3, count: 5))
        XCTAssertGreaterThan(tracker.fraction, reached)
    }

    func testWorkTypesMapTheirPhasesOntoOneBar() {
        XCTAssertEqual(WorkProgress.fetch(1, type: .pull), SummaryProgressTracker.ceiling)
        XCTAssertLessThan(WorkProgress.fetch(1, type: .pull), 1)
        XCTAssertEqual(WorkProgress.fetch(1, type: .summary), 0)
        XCTAssertEqual(WorkProgress.fetch(0.5, type: .chat), 0.15, accuracy: 1e-9)

        XCTAssertEqual(SummaryProgressTracker.fetchShare(pagesToFetch: 0), 0)
        XCTAssertLessThan(
            SummaryProgressTracker.fetchShare(pagesToFetch: 1),
            SummaryProgressTracker.fetchShare(pagesToFetch: 10)
        )
        XCTAssertLessThanOrEqual(SummaryProgressTracker.fetchShare(pagesToFetch: 200), 0.8)

        // Agent: steps used of the budget (plus the final answer).
        XCTAssertEqual(WorkProgress.agent(completedSteps: 0, maxSteps: 9), 0)
        XCTAssertEqual(WorkProgress.agent(completedSteps: 3, maxSteps: 9), 0.3, accuracy: 1e-9)
        XCTAssertEqual(WorkProgress.agent(completedSteps: 3, maxSteps: 9, within: 0.5), 0.35, accuracy: 1e-9)
        XCTAssertLessThan(
            WorkProgress.agent(completedSteps: 3, maxSteps: 9, within: 1),
            WorkProgress.agent(completedSteps: 4, maxSteps: 9),
            "a sub-step never reaches the next step"
        )
        XCTAssertLessThan(WorkProgress.agent(completedSteps: 40, maxSteps: 9), 1)

        XCTAssertEqual(WorkProgress.advanced(from: 0.6, to: 0.4), 0.6, "never backwards")
        XCTAssertEqual(WorkProgress.advanced(from: 0.4, to: 0.6), 0.6)
        XCTAssertEqual(WorkProgress.advanced(from: nil, to: 0.2), 0.2)
        XCTAssertNil(WorkProgress.advanced(from: 0.3, to: nil), "indeterminate is always allowed")
    }

    func testSummaryProgressCreepStaysWithinCurrentStepAndPullStaysBelow100UntilDone() {
        // Narrow batch (1 of 15, upperBound 0.048): long wait + stream + ticks stay within batch 1.
        var narrowBatch = SummaryProgressTracker(inputCharacters: 500_000)
        narrowBatch.apply(.batchStarted(level: 1, index: 0, count: 15), elapsed: 0)
        _ = narrowBatch.tick(elapsed: 14)
        narrowBatch.apply(.streamed(characters: 3_000), elapsed: 14)
        let duringBatch1Of15 = narrowBatch.tick(elapsed: 34)
        XCTAssertLessThanOrEqual(duringBatch1Of15, SummaryProgressTracker.sectionsEnd / 15)

        // Narrow fetch page (page 1 of 18): slow download ticks stay within page 1's slice.
        var narrowFetch = SummaryProgressTracker()
        narrowFetch.apply(.fetched(completedPages: 0, totalPages: 18), elapsed: 0)
        let firstPageEnd = SummaryProgressTracker.fetchShare(pagesToFetch: 18) / 18
        XCTAssertLessThanOrEqual(narrowFetch.tick(elapsed: 30), firstPageEnd)

        // Pause between batchFinished(0) and batchStarted(1) never creeps into batch 2.
        var betweenBatches = SummaryProgressTracker(inputCharacters: 500_000)
        betweenBatches.apply(.batchStarted(level: 1, index: 0, count: 10), elapsed: 0)
        betweenBatches.apply(.batchFinished(level: 1, index: 0, count: 10), elapsed: 2)
        let whileWaitingForBatch2 = betweenBatches.tick(elapsed: 12)
        XCTAssertLessThanOrEqual(whileWaitingForBatch2, SummaryProgressTracker.sectionsEnd / 10)

        // Pull progress stays below 100% while pages fetch.
        XCTAssertLessThan(WorkProgress.fetch(1.0, type: .pull), 1.0)
    }

    func testProgressStoreAdvancesMonotonicallySkipsDuplicatesAndClears() {
        let store = ProgressStore()
        var publishes = 0
        let cancellable = store.objectWillChange.sink { publishes += 1 }
        let id = UUID()

        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.value(for: id))

        store.advance(id, to: nil)
        XCTAssertEqual(publishes, 0, "nil-to-nil does not publish")

        store.advance(id, to: 0.25)
        XCTAssertEqual(store.value(for: id), 0.25)
        XCTAssertEqual(publishes, 1)

        store.advance(id, to: 0.25)
        store.advance(id, to: 0.1)
        XCTAssertEqual(store.value(for: id), 0.25)
        XCTAssertEqual(publishes, 1)

        store.advance(id, to: 0.7)
        XCTAssertEqual(store.value(for: id), 0.7)
        XCTAssertEqual(publishes, 2)

        store.advance(id, to: nil)
        XCTAssertNil(store.value(for: id))
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(publishes, 3)

        store.set(0.5, for: id)
        XCTAssertEqual(store.value(for: id), 0.5)
        store.remove(id)
        store.remove(id)
        XCTAssertNil(store.value(for: id))
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(publishes, 5)
        withExtendedLifetime(cancellable) {}
    }

    // MARK: Fake-clock scenarios (6)

    func testScenarioCachedShortTopic() {
        var events: [(TimeInterval, ScenarioStep)] = [
            (0.1, .event(.fetched(completedPages: 1, totalPages: 1))),
            (0.1, .event(.finalStarted(combining: false))),
        ]
        for step in 1...18 {
            events.append((1.5 + Double(step) * 0.25, .event(.streamed(characters: step * 36))))
        }
        let samples = assertScenario(
            tracker: SummaryProgressTracker(cachedPages: 1, inputCharacters: 2_000),
            duration: 6.0,
            steps: events
        )
        XCTAssertLessThan(samples[1], 0.05, "0 pages to fetch gives the AI phase the whole bar")
    }

    func testScenarioLongFetch() {
        var events: [(TimeInterval, ScenarioStep)] = [
            (0.2, .event(.fetched(completedPages: 0, totalPages: 18)))
        ]
        for page in 1...18 {
            events.append((0.2 + Double(page) * (13.8 / 18.0), .event(.fetched(completedPages: page, totalPages: 18))))
        }
        events.append((14.0, .input(30_000)))
        events.append((14.0, .event(.finalStarted(combining: false))))
        for step in 1...18 {
            events.append((15.5 + Double(step) * 0.25, .event(.streamed(characters: step * 125))))
        }
        assertScenario(tracker: SummaryProgressTracker(cachedPages: 0), duration: 20.0, steps: events)
    }

    func testScenarioSlowFirstToken() {
        var events: [(TimeInterval, ScenarioStep)] = [
            (0.1, .event(.fetched(completedPages: 0, totalPages: 1))),
            (0.8, .event(.fetched(completedPages: 1, totalPages: 1))),
            (0.8, .input(8_000)),
            (0.8, .event(.finalStarted(combining: false))),
        ]
        for step in 1...20 {
            events.append((14.8 + Double(step) * 0.26, .event(.streamed(characters: step * 90))))
        }
        assertScenario(tracker: SummaryProgressTracker(cachedPages: 0), duration: 20.0, steps: events)
    }

    func testScenarioFastShortAnswer() {
        var events: [(TimeInterval, ScenarioStep)] = [
            (0.1, .event(.fetched(completedPages: 2, totalPages: 2))),
            (0.1, .event(.finalStarted(combining: false))),
        ]
        for step in 1...11 {
            events.append((0.75 + Double(step) * 0.25, .event(.streamed(characters: step * 45))))
        }
        assertScenario(
            tracker: SummaryProgressTracker(cachedPages: 2, inputCharacters: 1_500, previousSummaryCharacters: 450),
            duration: 3.5,
            steps: events
        )
    }

    func testScenarioAnswerMuchLongerThanExpected() {
        var events: [(TimeInterval, ScenarioStep)] = [
            (0.1, .event(.fetched(completedPages: 1, totalPages: 1))),
            (0.1, .event(.finalStarted(combining: false))),
        ]
        for step in 1...175 {
            events.append((1.25 + Double(step) * 0.25, .event(.streamed(characters: step * 70))))
        }
        assertScenario(
            tracker: SummaryProgressTracker(cachedPages: 1, inputCharacters: 2_500),
            duration: 45.0,
            steps: events,
            checksAccuracy: false
        )
    }

    func testScenarioUnevenBatches() {
        let sizes = [20_000, 3_000, 2_000]
        var events: [(TimeInterval, ScenarioStep)] = [
            (0.1, .event(.fetched(completedPages: 3, totalPages: 3))),
            (0.1, .event(.batchesPlanned(level: 1, sizes: sizes))),
            (0.1, .event(.batchStarted(level: 1, index: 0, count: 3))),
        ]
        for step in 1...35 {
            events.append((2.0 + Double(step) * 0.25, .event(.streamed(characters: step * 45))))
        }
        events.append((11.0, .event(.batchFinished(level: 1, index: 0, count: 3))))
        events.append((11.0, .event(.batchStarted(level: 1, index: 1, count: 3))))
        for step in 1...7 {
            events.append((11.75 + Double(step) * 0.25, .event(.streamed(characters: step * 80))))
        }
        events.append((13.75, .event(.batchFinished(level: 1, index: 1, count: 3))))
        events.append((13.75, .event(.batchStarted(level: 1, index: 2, count: 3))))
        for step in 1...6 {
            events.append((14.5 + Double(step) * 0.25, .event(.streamed(characters: step * 80))))
        }
        events.append((16.0, .event(.batchFinished(level: 1, index: 2, count: 3))))
        events.append((16.0, .event(.finalStarted(combining: true))))
        for step in 1...13 {
            events.append((16.75 + Double(step) * 0.25, .event(.streamed(characters: step * 150))))
        }
        assertScenario(
            tracker: SummaryProgressTracker(cachedPages: 3, inputCharacters: 25_000),
            duration: 20.0,
            steps: events
        )
    }

    private enum ScenarioStep {
        case event(SummaryProgressEvent)
        case input(Int)
    }

    @discardableResult
    private func assertScenario(
        tracker: SummaryProgressTracker,
        duration: TimeInterval,
        steps: [(TimeInterval, ScenarioStep)],
        checksAccuracy: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [Double] {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var clock = start
        let store = ProgressStore()
        let id = UUID()
        let output = ThrottledProgress(interval: 0, now: { clock }) { fraction, _ in
            store.advance(id, to: fraction)
        }
        let feed = SummaryProgressFeed(tracker: tracker, output: output, now: { clock }, tickInterval: nil)
        let sorted = steps.sorted { $0.0 < $1.0 }
        var cursor = 0
        var times: [TimeInterval] = []
        var samples: [Double] = []
        let dt = 0.25
        var elapsed = 0.0

        while elapsed <= duration + 1e-9 {
            while cursor < sorted.count, sorted[cursor].0 <= elapsed + 1e-9 {
                clock = start.addingTimeInterval(sorted[cursor].0)
                switch sorted[cursor].1 {
                case .event(let event): feed.handle(event)
                case .input(let count): feed.setInputCharacters(count)
                }
                cursor += 1
            }
            clock = start.addingTimeInterval(elapsed)
            feed.tick()
            times.append(elapsed)
            samples.append(store.value(for: id) ?? 0)
            elapsed += dt
        }

        XCTAssertEqual(samples, samples.sorted(), "monotonic throughout the run", file: file, line: line)
        XCTAssertTrue(samples.allSatisfy { $0 < 1 }, "below 100% until finished", file: file, line: line)

        // No stall over 3 seconds (12 samples at 0.25s).
        let window = 12
        for index in 0..<(samples.count - window) {
            XCTAssertGreaterThan(
                samples[index + window] - samples[index],
                0.0005,
                "stalled over 3s starting at t=\(times[index])s",
                file: file,
                line: line
            )
        }

        if checksAccuracy {
            let within15 = zip(times, samples).filter { abs($1 - $0 / duration) <= 0.15 }.count
            XCTAssertGreaterThan(
                Double(within15) / Double(samples.count),
                0.70,
                "within 15 points of true elapsed share for most of the run",
                file: file,
                line: line
            )
        }

        clock = start.addingTimeInterval(duration)
        feed.finish()
        XCTAssertEqual(store.value(for: id), 1, "ends at 100% cleanly", file: file, line: line)
        XCTAssertTrue(feed.isStopped, file: file, line: line)
        return samples
    }

    // MARK: Throttling & feed lifecycle

    func testThrottleAllowsOneWritePerInterval() {
        var throttle = ProgressThrottle(interval: 0.1)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertNil(throttle.delay(at: start))
        XCTAssertEqual(throttle.delay(at: start.addingTimeInterval(0.03)) ?? 0, 0.07, accuracy: 1e-9)
        XCTAssertNotNil(throttle.delay(at: start.addingTimeInterval(0.09)))
        XCTAssertNil(throttle.delay(at: start.addingTimeInterval(0.1)))
        XCTAssertNil(throttle.delay(at: start.addingTimeInterval(0.12), force: true))
    }

    func testThrottledProgressCoalescesAndWritesTheLatestValue() async throws {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        var writes: [(Double?, String?)] = []
        let progress = ThrottledProgress(interval: 0.1, now: { clock }) { writes.append(($0, $1)) }

        // A burst of 100 reports within one interval: one write now...
        for step in 1...100 { progress.report(Double(step) / 100) }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.last?.0, 0.01)
        // ...and the latest value once the slot comes.
        clock.addTimeInterval(0.1)
        try await waitUntil { writes.count == 2 }
        XCTAssertEqual(writes.last?.0, 1)

        // A new status is written at once, with the latest fraction.
        progress.report(0.5)
        progress.report(0.6, statusText: "Combining…")
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes.last?.0, 0.6)
        XCTAssertEqual(writes.last?.1, "Combining…")

        // A forced status write replaces the pending slot: the cancelled
        // wait must not write again before the interval is up.
        clock.addTimeInterval(1)
        writes = []
        progress.report(0.61)
        progress.report(0.62)
        progress.report(0.63, statusText: "Summarizing part 2 of 7…")
        progress.report(0.64)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.1, "Summarizing part 2 of 7…")
        clock.addTimeInterval(0.1)
        try await waitUntil { writes.count == 3 }
        XCTAssertEqual(writes.last?.0, 0.64)

        // Cancelled (the job ended): pending and later reports are dropped.
        progress.report(0.7)
        progress.cancel()
        progress.report(0.8, statusText: "Late")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(writes.count, 3)
    }

    func testSummaryFeedTicksOnlyProgressAndStopsWhenCancelledOrFinished() async throws {
        var writes: [(Double?, String?)] = []
        let output = ThrottledProgress(interval: 0) { writes.append(($0, $1)) }
        let feed = SummaryProgressFeed(output: output, tickInterval: .milliseconds(25)) { 0.4 + 0.55 * $0 }
        feed.handle(.batchStarted(level: 1, index: 0, count: 2))
        XCTAssertEqual(writes.last?.0 ?? 0, 0.4, accuracy: 0.01)
        XCTAssertEqual(writes.last?.1, "Summarizing part 1 of 2…")

        try await waitUntil { writes.count >= 3 }
        XCTAssertTrue(writes.dropFirst().allSatisfy { $0.1 == nil }, "periodic ticks never rewrite status text")
        XCTAssertGreaterThan(writes.last?.0 ?? 0, 0.4)

        feed.cancel()
        let countAtCancel = writes.count
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(writes.count, countAtCancel, "tick stops as soon as work is cancelled")
    }

    // MARK: Progress bar motion

    func testIndeterminateSweepMovesWithTheClock() {
        let period = AssistantProgressBar.sweepPeriod
        let offsets = stride(from: 0.0, to: period * 3, by: 0.5).map {
            AssistantProgressBar.sweepOffset(at: 10_000 + $0)
        }
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            XCTAssertGreaterThan(abs(next - previous), 0.01, "the sweep moves between frames")
        }
        for offset in offsets {
            XCTAssertGreaterThanOrEqual(offset, -0.1 - 1e-9)
            XCTAssertLessThanOrEqual(offset, 0.8 + 1e-9)
        }
        XCTAssertGreaterThan(offsets.max() ?? 0, 0.7)
        XCTAssertLessThan(offsets.min() ?? 1, 0)
        let pulses = stride(from: 0.0, to: 2.4, by: 0.3).map {
            AssistantProgressBar.pulse(at: $0, low: 0.25, high: 0.65)
        }
        XCTAssertGreaterThan(Set(pulses.map { ($0 * 1_000).rounded() }).count, 4, "Reduce Motion still pulses")
        XCTAssertTrue(pulses.allSatisfy { (0.25...0.65).contains($0) })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Summary run state

    private func summaryRecord(_ topic: String, _ status: WorkStatus, error: String = "", age: TimeInterval = 0, type: WorkType = .summary) -> WorkRecord {
        var record = WorkRecord(type: type, siteURL: "https://a.example.org", topicID: topic, title: "T", url: URL(string: "https://a.example.org/t/\(topic)")!, provider: .ollama, model: "m")
        record.status = status
        record.error = error
        record.createdAt = Date(timeIntervalSince1970: 1_000 + age)
        return record
    }

    func testAFailedSummaryShowsItsErrorUntilANewerRunReplacesIt() {
        let key = summaryRecord("1", .failed).topicKey
        XCTAssertEqual(SummaryRunState.resolve([], topicKey: key), .idle)

        let failed = summaryRecord("1", .failed, error: "Offline", age: 0)
        XCTAssertEqual(SummaryRunState.resolve([failed], topicKey: key), .failed(message: "Offline"))

        let retry = summaryRecord("1", .queued, age: 10)
        XCTAssertEqual(SummaryRunState.resolve([failed, retry], topicKey: key), .running)
        var done = retry
        done.status = .completed
        XCTAssertEqual(SummaryRunState.resolve([failed, done], topicKey: key), .idle)
        let again = summaryRecord("1", .failed, error: "Timeout", age: 20)
        XCTAssertEqual(SummaryRunState.resolve([again, done, failed], topicKey: key), .failed(message: "Timeout"))
    }

    func testSummaryRunStateIgnoresOtherTopicsOtherWorkAndCancelledRuns() {
        let key = summaryRecord("1", .failed).topicKey
        let other = summaryRecord("2", .failed, error: "x")
        let chat = summaryRecord("1", .failed, error: "chat", type: .chat)
        XCTAssertEqual(SummaryRunState.resolve([other, chat], topicKey: key), .idle)
        let cancelled = summaryRecord("1", .cancelled, age: 5)
        XCTAssertEqual(SummaryRunState.resolve([summaryRecord("1", .failed, error: "e"), cancelled], topicKey: key), .idle)
    }
}
