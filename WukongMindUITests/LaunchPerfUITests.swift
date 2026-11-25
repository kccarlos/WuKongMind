import XCTest

/// Launch-to-interactive timing measurements (WUKO-213) for:
/// 1. First-run Terms of Use gate interactive (`termsAgree` hittable)
/// 2. Cold start to Home interactive (`browserTitle` hittable) with launch logo animation ON vs OFF
///
/// Not pass/fail on wall time: prints raw millisecond values for 3 runs each
/// and attaches them as `launch-perf.txt`.
final class LaunchPerfUITests: DCUITestCase {
    override var disablesAnimations: Bool { false }

    private func setLaunchLogoAnimation(enabled: Bool) {
        let settingsApp = XCUIApplication()
        settingsApp.launchArguments = ["-dc-skip-onboarding", "-dc-no-animations", "-dc-show-settings", "browser"]
        settingsApp.launch()
        let toggle = settingsApp.switches["launchLogoAnimationToggle"].firstMatch
        for _ in 0..<5 where !toggle.exists {
            settingsApp.swipeUp()
        }
        XCTAssertTrue(waitOrDump(toggle, timeout: 10, in: settingsApp), "launchLogoAnimationToggle not found")
        let target = enabled ? "1" : "0"
        if (toggle.value as? String) != target {
            toggle.tap()
            XCTAssertTrue(wait(timeout: 5) { (toggle.value as? String) == target })
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        settingsApp.terminate()
    }

    private func measureTermsGateInteractive(runs: Int) -> [Int] {
        var samples: [Int] = []
        for run in 1...runs {
            let app = XCUIApplication()
            app.launchArguments = ["-dc-reset"]
            let start = DispatchTime.now().uptimeNanoseconds
            app.launch()
            let agree = app.switches["termsAgree"].firstMatch
            XCTAssertTrue(waitForHittable(agree, timeout: 20), "Run \(run): termsAgree not hittable")
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            samples.append(ms)
            print("LAUNCH-PERF | terms_gate run=\(run) ms=\(ms)")
            app.terminate()
        }
        return samples
    }

    private func measureColdStartInteractive(runs: Int, label: String) -> [Int] {
        var samples: [Int] = []
        for run in 1...runs {
            let app = XCUIApplication()
            app.launchArguments = ["-dc-skip-onboarding", "-dc-forums-home", "-dc-seed-forums"]
            let start = DispatchTime.now().uptimeNanoseconds
            app.launch()
            let title = app.buttons["browserTitle"]
            XCTAssertTrue(waitForHittable(title, timeout: 20), "Run \(run) (\(label)): browserTitle not hittable")
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            samples.append(ms)
            print("LAUNCH-PERF | cold_start_\(label) run=\(run) ms=\(ms)")
            app.terminate()
        }
        return samples
    }

    func testLaunchToInteractivePerf() throws {
        try skipUnlessPhone("Launch perf targets iPhone simulator.")
        setLaunchLogoAnimation(enabled: true)
        let terms = measureTermsGateInteractive(runs: 3)
        let coldOn = measureColdStartInteractive(runs: 3, label: "on")
        setLaunchLogoAnimation(enabled: false)
        let coldOff = measureColdStartInteractive(runs: 3, label: "off")
        setLaunchLogoAnimation(enabled: true)

        let summary = """
        terms_gate_ms=\(terms)
        cold_start_on_ms=\(coldOn)
        cold_start_off_ms=\(coldOff)
        """
        print("LAUNCH-PERF | SUMMARY\n\(summary)")
        attachText(summary, named: "launch-perf.txt")
    }
}
