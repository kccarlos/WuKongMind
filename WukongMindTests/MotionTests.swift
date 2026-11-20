import XCTest
@testable import WukongMind

/// Spec §13: the timings behind the motion polish (the views only apply them).
@MainActor
final class MotionTests: XCTestCase {
    func testResultCardsRise12PointsStaggeredBy40MillisecondsOrFadeOnly() {
        XCTAssertEqual(ResultCardMotion.delay(order: 0, reduceMotion: false), 0)
        XCTAssertEqual(ResultCardMotion.delay(order: 3, reduceMotion: false), 0.12, accuracy: 1e-9)
        XCTAssertEqual(ResultCardMotion.delay(order: 50, reduceMotion: false), ResultCardMotion.delay(order: ResultCardMotion.staggeredCards, reduceMotion: false),
                       "late cards come in with the eighth")
        XCTAssertEqual(ResultCardMotion.offset(revealed: false, reduceMotion: false), 12)
        XCTAssertEqual(ResultCardMotion.offset(revealed: true, reduceMotion: false), 0)
        // Reduce Motion: fade only, no stagger.
        XCTAssertEqual(ResultCardMotion.offset(revealed: false, reduceMotion: true), 0)
        XCTAssertEqual(ResultCardMotion.delay(order: 5, reduceMotion: true), 0)
    }
}
