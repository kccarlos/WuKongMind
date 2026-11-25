import SwiftUI
import XCTest
@testable import WukongMind

/// Spec §13 & WUKO-213: the timings and policies behind the motion polish (the views only apply them).
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

    func testTermsGateLogoAssemblyPlaysOnlyOnFirstAppearanceWithoutReduceMotion() {
        XCTAssertTrue(LogoAssemblyPolicy.shouldAnimateOnTermsGate(isFirstAppearance: true, reduceMotion: false))
        XCTAssertFalse(LogoAssemblyPolicy.shouldAnimateOnTermsGate(isFirstAppearance: false, reduceMotion: false))
        XCTAssertFalse(LogoAssemblyPolicy.shouldAnimateOnTermsGate(isFirstAppearance: true, reduceMotion: true))
        XCTAssertFalse(LogoAssemblyPolicy.shouldAnimateOnTermsGate(isFirstAppearance: false, reduceMotion: true))
        XCTAssertFalse(LogoAssemblyPolicy.shouldAnimateOnTermsGate(isFirstAppearance: true, reduceMotion: false, animationsEnabled: false))
    }

    func testLaunchLogoOverlayPolicyRespectsSettingColdStartTermsAndAccessibility() {
        XCTAssertTrue(LogoAssemblyPolicy.shouldShowLaunchOverlay(
            settingEnabled: true,
            isColdStart: true,
            needsTermsAcceptance: false,
            reduceMotion: false,
            voiceOverRunning: false
        ))
        // Switch off → no overlay.
        XCTAssertFalse(LogoAssemblyPolicy.shouldShowLaunchOverlay(
            settingEnabled: false,
            isColdStart: true,
            needsTermsAcceptance: false,
            reduceMotion: false,
            voiceOverRunning: false
        ))
        // Warm foreground return → no overlay.
        XCTAssertFalse(LogoAssemblyPolicy.shouldShowLaunchOverlay(
            settingEnabled: true,
            isColdStart: false,
            needsTermsAcceptance: false,
            reduceMotion: false,
            voiceOverRunning: false
        ))
        // First run (Terms gate showing) → no overlay.
        XCTAssertFalse(LogoAssemblyPolicy.shouldShowLaunchOverlay(
            settingEnabled: true,
            isColdStart: true,
            needsTermsAcceptance: true,
            reduceMotion: false,
            voiceOverRunning: false
        ))
        // Reduce Motion → no overlay regardless of switch.
        XCTAssertFalse(LogoAssemblyPolicy.shouldShowLaunchOverlay(
            settingEnabled: true,
            isColdStart: true,
            needsTermsAcceptance: false,
            reduceMotion: true,
            voiceOverRunning: false
        ))
        // VoiceOver → no overlay.
        XCTAssertFalse(LogoAssemblyPolicy.shouldShowLaunchOverlay(
            settingEnabled: true,
            isColdStart: true,
            needsTermsAcceptance: false,
            reduceMotion: false,
            voiceOverRunning: true
        ))
    }

    func testBrandLogoAssemblyTimingAndHalfRingsShapeProgress() {
        XCTAssertLessThanOrEqual(BrandLogoAssemblyTiming.assemblyDuration, 0.8)
        XCTAssertLessThanOrEqual(BrandLogoAssemblyTiming.totalOverlayDuration, 0.8)
        XCTAssertLessThan(BrandLogoAssemblyTiming.halvesDuration, BrandLogoAssemblyTiming.assemblyDuration)

        // Rings draw from centre outward (inner > middle > outer at mid-assembly).
        let mid: CGFloat = 0.50
        let inner = BrandLogoAssemblyTiming.ringProgress(index: 0, progress: mid)
        let middle = BrandLogoAssemblyTiming.ringProgress(index: 1, progress: mid)
        let outer = BrandLogoAssemblyTiming.ringProgress(index: 2, progress: mid)
        XCTAssertGreaterThan(inner, middle)
        XCTAssertGreaterThan(middle, outer)

        // At progress 0 no ring paths are drawn; at progress 1 all rings are full.
        let rect = CGRect(x: 0, y: 0, width: 120, height: 120)
        XCTAssertTrue(BrandHalfRingsShape(isLeft: false, progress: 0).path(in: rect).isEmpty)
        XCTAssertTrue(BrandHalfRingsShape(isLeft: true, progress: 0).path(in: rect).isEmpty)
        XCTAssertFalse(BrandHalfRingsShape(isLeft: false, progress: 1).path(in: rect).isEmpty)
        XCTAssertFalse(BrandHalfRingsShape(isLeft: true, progress: 1).path(in: rect).isEmpty)
    }

    func testLaunchLogoAnimationSettingDefaultsOnPersistsAndSyncs() throws {
        XCTAssertTrue(AppSettings().launchLogoAnimationEnabled)
        let bare = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(bare.launchLogoAnimationEnabled)

        var off = AppSettings()
        off.launchLogoAnimationEnabled = false
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(roundTrip.launchLogoAnimationEnabled)

        let units = try SyncSchema.settingsUnits(off)
        XCTAssertEqual(units["launchLogoAnimationEnabled"], .bool(false))
        let merged = try SyncSchema.applying(settingsUnits: units, to: AppSettings())
        XCTAssertFalse(merged.launchLogoAnimationEnabled)
    }
}
