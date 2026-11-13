import SwiftUI
import UIKit
import XCTest
@testable import WukongMind

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

    private struct RGBA: Equatable {
        let r: Int
        let g: Int
        let b: Int
        let a: CGFloat
    }

    private func rgba(_ color: Color, _ mode: Mode) -> RGBA {
        let resolved = UIColor(color).resolvedColor(with: mode.traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(
            r: Int((r * 255).rounded()),
            g: Int((g * 255).rounded()),
            b: Int((b * 255).rounded()),
            a: a
        )
    }

    private func hex(_ color: Color, _ mode: Mode) -> UInt32 {
        let c = rgba(color, mode)
        return UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
    }

    private func relativeLuminance(_ c: RGBA) -> Double {
        func channel(_ byte: Int) -> Double {
            let s = Double(byte) / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrastRatio(_ fg: Color, on bg: Color, mode: Mode) -> Double {
        let l1 = relativeLuminance(rgba(fg, mode))
        let l2 = relativeLuminance(rgba(bg, mode))
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func testAllOpaqueColourTokensMatchDesignSystemSpec() {
        let opaqueTokens: [(name: String, color: Color, light: UInt32, dark: UInt32)] = [
            ("ground", DCTheme.ground, 0xF7F3EA, 0x14110E),
            ("surface", DCTheme.surface, 0xFFFDF8, 0x1F1B16),
            ("surfaceRaised", DCTheme.surfaceRaised, 0xEFE9DC, 0x2A251E),
            ("ink", DCTheme.ink, 0x1A1612, 0xF4EEE2),
            ("inkMuted", DCTheme.inkMuted, 0x5F574C, 0xB3A998),
            ("inkFaint", DCTheme.inkFaint, 0x756C5F, 0x8F8676),
            ("borderStrong", DCTheme.borderStrong, 0x8C8375, 0x7D7567),
            ("gold", DCTheme.gold, 0xB07F0C, 0xE0B040),
            ("onGold", DCTheme.onGold, 0x1A1612, 0x1A1612),
            ("goldInk", DCTheme.goldInk, 0x8A6200, 0xE8BD55),
            ("goldWash", DCTheme.goldWash, 0xF6ECD0, 0x3A2F14),
            ("jade", DCTheme.jade, 0x1F6F66, 0x6FD0C2),
            ("jadeWash", DCTheme.jadeWash, 0xDCEFEB, 0x12302C),
            ("cinnabar", DCTheme.cinnabar, 0xB3321F, 0xFF7A5C),
            ("onCinnabar", DCTheme.onCinnabar, 0xFFFFFF, 0x1A1612),
            ("cinnabarWash", DCTheme.cinnabarWash, 0xF9E1DA, 0x3D1A12),
            ("danger", DCTheme.danger, 0xB3321F, 0xFF7A5C),
            ("success", DCTheme.success, 0x356F1B, 0x8FD66B),
            ("warning", DCTheme.warning, 0xA34A08, 0xFFB070),
        ]

        for token in opaqueTokens {
            XCTAssertEqual(hex(token.color, .light), token.light, "\(token.name) light")
            XCTAssertEqual(hex(token.color, .dark), token.dark, "\(token.name) dark")
            XCTAssertEqual(rgba(token.color, .light).a, 1.0, accuracy: 0.01, "\(token.name) light alpha")
            XCTAssertEqual(rgba(token.color, .dark).a, 1.0, accuracy: 0.01, "\(token.name) dark alpha")
        }
    }

    func testTranslucentTokensAndIncreaseContrastHairline() {
        let translucentTokens: [(name: String, color: Color, lightHex: UInt32, lightAlpha: CGFloat, darkHex: UInt32, darkAlpha: CGFloat)] = [
            ("hairline", DCTheme.hairline, 0x1A1612, 0.14, 0xF4EEE2, 0.16),
            ("scrim", DCTheme.scrim, 0x14110E, 0.40, 0x000000, 0.50),
        ]

        for token in translucentTokens {
            XCTAssertEqual(hex(token.color, .light), token.lightHex, "\(token.name) light RGB")
            XCTAssertEqual(rgba(token.color, .light).a, token.lightAlpha, accuracy: 0.015, "\(token.name) light alpha")
            XCTAssertEqual(hex(token.color, .dark), token.darkHex, "\(token.name) dark RGB")
            XCTAssertEqual(rgba(token.color, .dark).a, token.darkAlpha, accuracy: 0.015, "\(token.name) dark alpha")
        }

        // Accessibility rule: Increase Contrast resolves `hairline` to `borderStrong`.
        XCTAssertEqual(rgba(DCTheme.hairline, .lightHighContrast), rgba(DCTheme.borderStrong, .lightHighContrast))
        XCTAssertEqual(rgba(DCTheme.hairline, .darkHighContrast), rgba(DCTheme.borderStrong, .darkHighContrast))
        XCTAssertEqual(hex(DCTheme.hairline, .lightHighContrast), 0x8C8375)
        XCTAssertEqual(hex(DCTheme.hairline, .darkHighContrast), 0x7D7567)
        XCTAssertEqual(rgba(DCTheme.hairline, .lightHighContrast).a, 1.0, accuracy: 0.01)
        XCTAssertEqual(rgba(DCTheme.hairline, .darkHighContrast).a, 1.0, accuracy: 0.01)
    }

    func testTextAndControlContrastMeetsWCAGAA() {
        let textPairs: [(label: String, fg: Color, bg: Color)] = [
            ("ink on ground", DCTheme.ink, DCTheme.ground),
            ("ink on surface", DCTheme.ink, DCTheme.surface),
            ("ink on surfaceRaised", DCTheme.ink, DCTheme.surfaceRaised),
            ("inkMuted on ground", DCTheme.inkMuted, DCTheme.ground),
            ("inkMuted on surface", DCTheme.inkMuted, DCTheme.surface),
            ("inkMuted on surfaceRaised", DCTheme.inkMuted, DCTheme.surfaceRaised),
            ("inkFaint on ground", DCTheme.inkFaint, DCTheme.ground),
            ("inkFaint on surface", DCTheme.inkFaint, DCTheme.surface),
            ("onGold on gold", DCTheme.onGold, DCTheme.gold),
            ("goldInk on ground", DCTheme.goldInk, DCTheme.ground),
            ("goldInk on surface", DCTheme.goldInk, DCTheme.surface),
            ("goldInk on goldWash", DCTheme.goldInk, DCTheme.goldWash),
            ("jade on ground", DCTheme.jade, DCTheme.ground),
            ("jade on surface", DCTheme.jade, DCTheme.surface),
            ("jade on jadeWash", DCTheme.jade, DCTheme.jadeWash),
            ("onCinnabar on cinnabar", DCTheme.onCinnabar, DCTheme.cinnabar),
            ("danger on ground", DCTheme.danger, DCTheme.ground),
            ("danger on surface", DCTheme.danger, DCTheme.surface),
            ("danger on cinnabarWash", DCTheme.danger, DCTheme.cinnabarWash),
            ("success on ground", DCTheme.success, DCTheme.ground),
            ("success on surface", DCTheme.success, DCTheme.surface),
            ("warning on ground", DCTheme.warning, DCTheme.ground),
            ("warning on surface", DCTheme.warning, DCTheme.surface),
            ("ground on ink (ink seal / tile)", DCTheme.ground, DCTheme.ink),
        ]

        for mode in [Mode.light, .dark] {
            for pair in textPairs {
                let ratio = contrastRatio(pair.fg, on: pair.bg, mode: mode)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "\(pair.label) in \(mode) had contrast \(String(format: "%.2f", ratio)):1 (< 4.5:1)"
                )
            }
            // Non-text control contrast checks (>= 3.0:1).
            for (label, fg, bg) in [
                ("borderStrong on ground", DCTheme.borderStrong, DCTheme.ground),
                ("borderStrong on surface", DCTheme.borderStrong, DCTheme.surface),
                ("gold ring on ground", DCTheme.gold, DCTheme.ground),
                ("gold ring on surface", DCTheme.gold, DCTheme.surface),
                ("Switch off knob (inkMuted on surface)", DCTheme.inkMuted, DCTheme.surface),
                ("Switch on knob (onGold on gold)", DCTheme.onGold, DCTheme.gold),
            ] {
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(fg, on: bg, mode: mode),
                    3.0,
                    "\(label) in \(mode)"
                )
            }
        }
    }

    func testDimensionsRoleMappingsAndAssetColors() throws {
        XCTAssertEqual(DCTheme.space1, 4)
        XCTAssertEqual(DCTheme.space2, 8)
        XCTAssertEqual(DCTheme.space3, 12)
        XCTAssertEqual(DCTheme.space4, 16)
        XCTAssertEqual(DCTheme.space6, 24)
        XCTAssertEqual(DCTheme.space8, 32)
        XCTAssertEqual(DCTheme.radiusSm, 6)
        XCTAssertEqual(DCTheme.radiusMd, 10)
        XCTAssertEqual(DCTheme.radiusLg, 14)
        XCTAssertEqual(DCTheme.radiusSheet, 28)
        XCTAssertEqual(DCTheme.radiusFull, 999)
        XCTAssertEqual(DCTheme.hairlineWidth, 1)
        XCTAssertEqual(DCTheme.ringWidth, 2)
        XCTAssertEqual(DCTheme.forumPalette.count, 8)

        XCTAssertEqual(DCTheme.postHighlightStrokeWidth(highContrast: false), 2)
        XCTAssertEqual(DCTheme.postHighlightStrokeWidth(highContrast: true), 3)
        XCTAssertEqual(hex(DCTheme.postHighlightStroke, .light), 0x1F6F66)
        XCTAssertEqual(hex(DCTheme.postHighlightStroke, .dark), 0x6FD0C2)
        XCTAssertEqual(DCTheme.postHighlightStroke.cssHex(dark: false, highContrast: false), "#1F6F66")
        XCTAssertEqual(DCTheme.postHighlightStroke.cssHex(dark: true, highContrast: false), "#6FD0C2")
        XCTAssertEqual(hex(DCTheme.chatTint, .light), 0x1F6F66)
        XCTAssertEqual(hex(DCTheme.chatTint, .dark), 0x6FD0C2)

        let bundle = Bundle(for: AppModel.self)
        let launch = try XCTUnwrap(UIColor(named: "LaunchBackground", in: bundle, compatibleWith: nil))
        XCTAssertEqual(hex(Color(uiColor: launch), .light), 0xF7F3EA)
        XCTAssertEqual(hex(Color(uiColor: launch), .dark), 0x14110E)

        let accent = try XCTUnwrap(UIColor(named: "AccentColor", in: bundle, compatibleWith: nil))
        XCTAssertEqual(hex(Color(uiColor: accent), .light), 0x8A6200)
        XCTAssertEqual(hex(Color(uiColor: accent), .dark), 0xE8BD55)
    }

    func testLogoAndMascotVectorAssetsLoadAndRenderWithoutClipping() throws {
        let bundle = Bundle(for: AppModel.self)
        let assetNames = DCLogoVariant.allCases.map(\.assetName) + DCMascotPose.allCases.map(\.assetName)
        XCTAssertEqual(assetNames.count, 8)

        let canvas = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        for name in assetNames {
            let image = try XCTUnwrap(UIImage(named: name, in: bundle, compatibleWith: nil), "Missing vector asset \(name)")
            XCTAssertGreaterThan(image.size.width, 0, "\(name) width")
            XCTAssertGreaterThan(image.size.height, 0, "\(name) height")

            let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                let scale = min(canvas.width / image.size.width, canvas.height / image.size.height)
                let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let origin = CGPoint(x: (canvas.width - drawSize.width) / 2, y: (canvas.height - drawSize.height) / 2)
                image.draw(in: CGRect(origin: origin, size: drawSize))
            }
            let cg = try XCTUnwrap(rendered.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data)
            let ptr = try XCTUnwrap(CFDataGetBytePtr(data))
            let bpp = cg.bitsPerPixel / 8
            let bpr = cg.bytesPerRow

            var opaquePixelCount = 0
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    let alpha = ptr[y * bpr + x * bpp + (bpp - 1)]
                    if alpha > 32 {
                        opaquePixelCount += 1
                    }
                }
            }
            XCTAssertGreaterThan(opaquePixelCount, 200, "Vector asset \(name) rendered blank or nearly empty (\(opaquePixelCount) pixels).")
        }
    }

    @MainActor
    func testSharedDesignSystemComponentsRenderCleanly() {
        let showcase = VStack(spacing: DCTheme.space2) {
            Button("Primary") {}
                .buttonStyle(DCButtonStyle(role: .primary, fullWidth: true))
            Button("Secondary") {}
                .buttonStyle(DCButtonStyle(role: .secondary))
            Button("Quiet") {}
                .buttonStyle(DCButtonStyle(role: .quiet))
            Button("Stop") {}
                .buttonStyle(DCButtonStyle(role: .destructive))
            HStack {
                DCSeal(text: "2", variant: .ink)
                DCSeal(text: "Sonnet", variant: .outline)
                DCSeal(text: "Saved", variant: .gold, showsAgentRing: true)
                DCSeal(text: "Discourse", variant: .jade)
                DCSeal(text: "Ready", variant: .state(.ready))
            }
            Toggle("Run on site", isOn: .constant(true))
                .toggleStyle(DCSwitchStyle())
            Toggle("Disabled off", isOn: .constant(false))
                .toggleStyle(DCSwitchStyle())
            DCListRow(title: "Browser Agent", subtitle: "Gold icon tile", value: "On", icon: .agent, showsChevron: true)
            DCListRow(title: "Sites", value: "3", icon: .ink(symbol: "globe"), showsChevron: true)
            HStack {
                DCAgentRing(size: 22, isTurning: false)
                DCAgentRing(size: 22, isTurning: true)
                DCLogoView(variant: .mark, size: 32, showsWordmark: true)
                DCMascotView(pose: .wave, size: 20) // clamped to >= 40pt
            }
        }
        .padding()
        .background(DCTheme.ground)

        let renderer = ImageRenderer(content: showcase.frame(width: 360))
        renderer.scale = 1
        let image = renderer.uiImage
        XCTAssertNotNil(image)
        XCTAssertEqual(Int(image?.size.width ?? 0), 360)
        XCTAssertGreaterThan(Int(image?.size.height ?? 0), 280)

        let smallMascotRenderer = ImageRenderer(content: DCMascotView(pose: .think, size: 16))
        smallMascotRenderer.scale = 1
        XCTAssertEqual(smallMascotRenderer.uiImage?.size.width ?? 0, DCMascotView.minimumSize, accuracy: 0.5)
    }

    @MainActor
    func testHistoryFilterSelectedChipUsesGoldTokenInDarkMode() throws {
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

        let darkGold = rgba(DCTheme.gold, .dark)
        let bpp = cgImage.bitsPerPixel / 8
        let bpr = cgImage.bytesPerRow
        var foundDarkGold = false
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = y * bpr + x * bpp
                let b0 = Int(ptr[offset])
                let b1 = Int(ptr[offset + 1])
                let b2 = Int(ptr[offset + 2])
                let rgbMatch = abs(b0 - darkGold.r) <= 16 && abs(b1 - darkGold.g) <= 16 && abs(b2 - darkGold.b) <= 16
                let bgrMatch = abs(b2 - darkGold.r) <= 16 && abs(b1 - darkGold.g) <= 16 && abs(b0 - darkGold.b) <= 16
                if rgbMatch || bgrMatch {
                    foundDarkGold = true
                    break
                }
            }
            if foundDarkGold { break }
        }

        XCTAssertTrue(
            foundDarkGold,
            "Selected HistoryView filter chip in dark mode did not render DCTheme.gold (\(String(format: "#%02X%02X%02X", darkGold.r, darkGold.g, darkGold.b)))."
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
        XCTAssertNotNil(switchTint, "Settings toggle should set an explicit gold onTintColor instead of system green.")

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
