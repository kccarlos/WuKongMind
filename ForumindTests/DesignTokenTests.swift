import SwiftUI
import UIKit
import XCTest
@testable import Forumind

final class DesignTokenTests: XCTestCase {
    private enum Mode: CaseIterable {
        case light, dark, lightHighContrast, darkHighContrast

        var traits: UITraitCollection {
            let isDark = self == .dark || self == .darkHighContrast
            let isHigh = self == .lightHighContrast || self == .darkHighContrast
            return UITraitCollection { mutable in
                mutable.userInterfaceStyle = isDark ? .dark : .light
                mutable.accessibilityContrast = isHigh ? .high : .normal
            }
        }
    }

    private func hex(_ color: Color, _ mode: Mode) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: mode.traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private struct Expectation {
        let name: String
        let color: Color
        let light: UInt32
        let dark: UInt32
        let highContrastLight: UInt32
        let highContrastDark: UInt32
    }

    private var expectations: [Expectation] {
        [
            Expectation(name: "brandBlue", color: DCTheme.brandBlue, light: 0x3A5BE0, dark: 0x7B93FF, highContrastLight: 0x2A45B8, highContrastDark: 0xA9BAFF),
            Expectation(name: "brandPurple", color: DCTheme.brandPurple, light: 0x8E2DB5, dark: 0xC77DEB, highContrastLight: 0x6E1F8E, highContrastDark: 0xE0A8F7),
            Expectation(name: "chatTint", color: DCTheme.chatTint, light: 0x0E8A7E, dark: 0x4FD1C0, highContrastLight: 0x0A6B62, highContrastDark: 0x8BEBDD),
            Expectation(name: "newRepliesBadgeText", color: DCTheme.newRepliesBadgeText, light: 0x8A4A00, dark: 0xFFB44C, highContrastLight: 0x6E3A00, highContrastDark: 0xFFD08A),
            Expectation(name: "newRepliesBadgeBackground", color: DCTheme.newRepliesBadgeBackground, light: 0xFFF1DE, dark: 0x3A2A12, highContrastLight: 0xFFE6C4, highContrastDark: 0x2A1C08),
            Expectation(name: "postHighlightBackground", color: DCTheme.postHighlightBackground, light: 0xEEF1FF, dark: 0x1E2550, highContrastLight: 0xEEF1FF, highContrastDark: 0x1E2550),
        ]
    }

    func testTokensResolveInEveryAppearanceAndContrast() {
        for item in expectations {
            XCTAssertEqual(hex(item.color, .light), item.light, "\(item.name) light")
            XCTAssertEqual(hex(item.color, .dark), item.dark, "\(item.name) dark")
            XCTAssertEqual(hex(item.color, .lightHighContrast), item.highContrastLight, "\(item.name) light high contrast")
            XCTAssertEqual(hex(item.color, .darkHighContrast), item.highContrastDark, "\(item.name) dark high contrast")
        }
    }

    func testHighContrastDiffersWhereSpecified() {
        for item in expectations where item.name != "postHighlightBackground" {
            XCTAssertNotEqual(item.light, item.highContrastLight, "\(item.name) light")
            XCTAssertNotEqual(item.dark, item.highContrastDark, "\(item.name) dark")
        }
    }

    func testBrandInkUsesSystemLabelInHighContrast() {
        XCTAssertEqual(hex(DCTheme.brandInk, .light), 0x17132B)
        XCTAssertEqual(hex(DCTheme.brandInk, .dark), 0xF2F0FA)
        for mode in [Mode.lightHighContrast, .darkHighContrast] {
            let label = UIColor.label.resolvedColor(with: mode.traits)
            XCTAssertEqual(UIColor(DCTheme.brandInk).resolvedColor(with: mode.traits), label)
        }
        XCTAssertEqual(hex(DCTheme.brandInk, .lightHighContrast), 0x000000)
        XCTAssertEqual(hex(DCTheme.brandInk, .darkHighContrast), 0xFFFFFF)
    }

    func testPostHighlightStrokeIsBrandBlueAndThickerInHighContrast() {
        XCTAssertEqual(DCTheme.postHighlightStrokeWidth(highContrast: false), 2)
        XCTAssertEqual(DCTheme.postHighlightStrokeWidth(highContrast: true), 3)
        for mode in Mode.allCases {
            XCTAssertEqual(hex(DCTheme.postHighlightStroke, mode), hex(DCTheme.brandBlue, mode))
        }
        XCTAssertEqual(hex(DCTheme.postHighlightStroke, .light), 0x3A5BE0)
        XCTAssertEqual(hex(DCTheme.postHighlightStroke, .dark), 0x7B93FF)
    }

    func testLaunchBackgroundColorIsConfigured() throws {
        let color = try XCTUnwrap(UIColor(named: "LaunchBackground", in: Bundle(for: AppModel.self), compatibleWith: nil))
        func white(_ mode: Mode) -> CGFloat {
            var value: CGFloat = -1
            color.resolvedColor(with: mode.traits).getWhite(&value, alpha: nil)
            return value
        }
        XCTAssertEqual(white(.light), 1, accuracy: 0.01)
        XCTAssertEqual(white(.dark), 0, accuracy: 0.01)
    }

    @MainActor
    func testHistoryFilterSelectedChipUsesDarkBrandBlueToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppModel(
            store: PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()),
            backgroundScheduler: FakeTaskScheduler(),
            podcastDirectory: dir.appendingPathComponent("Podcasts", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil

        let size = CGSize(width: 390, height: 220)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: HistoryView(app: app).environment(\.colorScheme, .dark))
        host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 140), format: format).image { ctx in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: ctx.cgContext)
            }
        }
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data)
        else {
            XCTFail("Failed to capture HistoryView filter bar bitmap.")
            return
        }

        let darkBrand = UIColor(DCTheme.brandBlue).resolvedColor(with: Mode.dark.traits)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        darkBrand.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let wantR = Int((tr * 255).rounded())
        let wantG = Int((tg * 255).rounded())
        let wantB = Int((tb * 255).rounded())

        let bpp = cgImage.bitsPerPixel / 8
        let bpr = cgImage.bytesPerRow
        var foundDarkBrandBlue = false
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = y * bpr + x * bpp
                let b0 = Int(ptr[offset])
                let b1 = Int(ptr[offset + 1])
                let b2 = Int(ptr[offset + 2])
                // Match either RGB or BGR byte order within ±16 tolerance.
                let rgbMatch = abs(b0 - wantR) <= 16 && abs(b1 - wantG) <= 16 && abs(b2 - wantB) <= 16
                let bgrMatch = abs(b2 - wantR) <= 16 && abs(b1 - wantG) <= 16 && abs(b0 - wantB) <= 16
                if rgbMatch || bgrMatch {
                    foundDarkBrandBlue = true
                    break
                }
            }
            if foundDarkBrandBlue { break }
        }

        XCTAssertTrue(
            foundDarkBrandBlue,
            "Selected HistoryView filter chip in dark mode did not render DCTheme.brandBlue (\(String(format: "#%02X%02X%02X", wantR, wantG, wantB)))."
        )
    }

    @MainActor
    func testVoiceDockSurfaceBackground() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppModel(
            store: PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()),
            backgroundScheduler: FakeTaskScheduler(),
            podcastDirectory: dir.appendingPathComponent("Podcasts", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        app.voice.toggle()

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        // Voice dock over a black backdrop in light mode must stay opaque enough to prevent bleed-through.
        let dockSize = CGSize(width: 390, height: 120)
        let dockWindow = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: dockSize))
        dockWindow.frame = CGRect(origin: .zero, size: dockSize)
        dockWindow.overrideUserInterfaceStyle = .light
        let dockRoot = ZStack {
            Color.black
            DockLayer(app: app, browser: app.browser, voice: app.voice, router: app.router, podcast: app.podcast, showsHome: true)
                .padding(.horizontal, 16)
        }
        .environment(\.colorScheme, .light)
        let dockHost = UIHostingController(rootView: dockRoot)
        dockHost.overrideUserInterfaceStyle = .light
        dockWindow.rootViewController = dockHost
        dockWindow.makeKeyAndVisible()
        dockHost.view.frame = dockWindow.bounds
        dockWindow.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        dockWindow.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let dockImage = UIGraphicsImageRenderer(size: dockSize, format: format).image { ctx in
            if !dockWindow.drawHierarchy(in: dockWindow.bounds, afterScreenUpdates: true) {
                dockWindow.layer.render(in: ctx.cgContext)
            }
        }
        dockWindow.isHidden = true
        dockWindow.rootViewController = nil
        dockWindow.windowScene = nil

        guard let dockCG = dockImage.cgImage,
              let dockData = dockCG.dataProvider?.data,
              let dockPtr = CFDataGetBytePtr(dockData)
        else {
            XCTFail("Failed to capture VoiceDock bitmap.")
            return
        }
        let dockBpp = dockCG.bitsPerPixel / 8
        let dockBpr = dockCG.bytesPerRow
        var maxDockChannel = 0
        for y in 30..<90 {
            for x in 180..<260 {
                let offset = y * dockBpr + x * dockBpp
                let avg = (Int(dockPtr[offset]) + Int(dockPtr[offset + 1]) + Int(dockPtr[offset + 2])) / 3
                if avg > maxDockChannel { maxDockChannel = avg }
            }
        }

        XCTAssertGreaterThanOrEqual(maxDockChannel, 230, "VoiceDock background let underlying dark content bleed through (max brightness \(maxDockChannel)).")
    }

    @MainActor
    func testHistoryNavigationBarPocketSummaryMetaSwitchTintAndTranslationSheetBackground() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppModel(
            store: PersistentStore(fileURL: dir.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()),
            backgroundScheduler: FakeTaskScheduler(),
            podcastDirectory: dir.appendingPathComponent("Podcasts", isDirectory: true)
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        app.seedAssistantSample()

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        func firstScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews {
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        func allScrollViews(in view: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            if let scroll = view as? UIScrollView { result.append(scroll) }
            for sub in view.subviews { result.append(contentsOf: allScrollViews(in: sub)) }
            return result
        }

        func firstSwitch(in view: UIView) -> UISwitch? {
            if let toggle = view as? UISwitch { return toggle }
            for sub in view.subviews {
                if let found = firstSwitch(in: sub) { return found }
            }
            return nil
        }

        // 1. Finding 5: HistoryView's primary top UIScrollView must span the full width so UINavigationBar's top pocket does not clip behind Done.
        let historySize = CGSize(width: 393, height: 852)
        let historyWindow = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: historySize))
        historyWindow.frame = CGRect(origin: .zero, size: historySize)
        let historyHost = UIHostingController(rootView: ExpandedPanel(app: app, route: .history))
        historyWindow.rootViewController = historyHost
        historyWindow.makeKeyAndVisible()
        historyHost.view.frame = historyWindow.bounds
        historyWindow.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        historyWindow.layoutIfNeeded()
        let topScrollWidth = firstScrollView(in: historyHost.view)?.frame.width ?? 0
        historyWindow.isHidden = true
        historyWindow.rootViewController = nil
        historyWindow.windowScene = nil
        XCTAssertGreaterThanOrEqual(topScrollWidth, 390, "HistoryView's first UIScrollView is narrower than the sheet (\(topScrollWidth)pt), causing UINavigationBar's scroll pocket to clip behind Done.")

        // 2. Finding 27: AssistantPanel summaryMeta at narrow split width (380pt) must fit all four pills without horizontal overflow clipping "Kept".
        let panelSize = CGSize(width: 380, height: 640)
        let panelWindow = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: panelSize))
        panelWindow.frame = CGRect(origin: .zero, size: panelSize)
        let panelHost = UIHostingController(rootView: AssistantPanel(app: app, onExpand: { _ in }))
        panelWindow.rootViewController = panelHost
        panelWindow.makeKeyAndVisible()
        panelHost.view.frame = panelWindow.bounds
        panelWindow.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        panelWindow.layoutIfNeeded()
        let overflowingHorizontalScrolls = allScrollViews(in: panelHost.view).filter { scroll in
            let frameInPanel = scroll.convert(scroll.bounds, to: panelHost.view)
            return frameInPanel.minY < 250 && scroll.bounds.height < 50 && scroll.contentSize.width > scroll.bounds.width + 1
        }
        panelWindow.isHidden = true
        panelWindow.rootViewController = nil
        panelWindow.windowScene = nil
        XCTAssertTrue(overflowingHorizontalScrolls.isEmpty, "Summary meta chips overflowed horizontally at 380pt panel width, clipping Kept.")

        // 3. Finding 7: Toggles inside Settings/form sheets use DCTheme.brandBlue instead of system green.
        let settingsWindow = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: historySize))
        settingsWindow.frame = CGRect(origin: .zero, size: historySize)
        let settingsHost = UIHostingController(rootView: NavigationStack { SettingsDestination(app: app, page: .sync) })
        settingsWindow.rootViewController = settingsHost
        settingsWindow.makeKeyAndVisible()
        settingsHost.view.frame = settingsWindow.bounds
        settingsWindow.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        settingsWindow.layoutIfNeeded()
        let toggleSwitch = firstSwitch(in: settingsHost.view)
        let switchTint = toggleSwitch?.onTintColor
        settingsWindow.isHidden = true
        settingsWindow.rootViewController = nil
        settingsWindow.windowScene = nil
        XCTAssertNotNil(toggleSwitch, "Expected a UISwitch in SettingsSyncPage.")
        XCTAssertNotNil(switchTint, "Settings toggle should set an explicit brand onTintColor instead of system green.")

        // 4. Finding 8: PostsTranslationSheet uses DCTheme.pageBackground instead of pure white.
        let translateWindow = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: historySize))
        translateWindow.frame = CGRect(origin: .zero, size: historySize)
        translateWindow.overrideUserInterfaceStyle = .light
        let translateHost = UIHostingController(rootView: PostsTranslationSheet(app: app).environment(\.colorScheme, .light))
        translateHost.overrideUserInterfaceStyle = .light
        translateWindow.rootViewController = translateHost
        translateWindow.makeKeyAndVisible()
        translateHost.view.frame = translateWindow.bounds
        translateWindow.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        translateWindow.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let translateImage = UIGraphicsImageRenderer(size: historySize, format: format).image { ctx in
            if !translateWindow.drawHierarchy(in: translateWindow.bounds, afterScreenUpdates: true) {
                translateWindow.layer.render(in: ctx.cgContext)
            }
        }
        translateWindow.isHidden = true
        translateWindow.rootViewController = nil
        translateWindow.windowScene = nil

        if let cg = translateImage.cgImage,
           let data = cg.dataProvider?.data,
           let ptr = CFDataGetBytePtr(data) {
            let offset = 200 * cg.bytesPerRow + 20 * (cg.bitsPerPixel / 8)
            let r = Int(ptr[offset])
            let g = Int(ptr[offset + 1])
            let b = Int(ptr[offset + 2])
            XCTAssertLessThan(r, 252, "PostsTranslationSheet background was pure white (\(r), \(g), \(b)) instead of DCTheme.pageBackground.")
        } else {
            XCTFail("Failed to capture PostsTranslationSheet bitmap.")
        }
    }
}
