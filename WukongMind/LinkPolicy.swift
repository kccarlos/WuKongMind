import Foundation

// MARK: - Links, app links and the web user agent
//
// - `LinkPolicy.decide`        what to do with one navigation (pure, unit-tested)
// - `LinkSettings`             "Open links in apps" plus the per-site overrides
// - `LinkPolicy.userAgent`     the iOS Safari user agent every page sees
// - `AppOpenPrompt`            the small "This page wants to open <app>" banner
//
// A tapped https link would otherwise reach iOS Universal Links and jump to
// the site's app (x.com opens the X app). The browser cancels such a tap and
// loads the same URL itself, which never triggers an app link. Public API only.

struct LinkSettings: Equatable {
    /// The global "Open links in apps" switch (off by default).
    var openInApps = false
    /// Per-site overrides: normalized host → open in the app (true) or stay (false).
    var siteOverrides: [String: Bool] = [:]

    /// The override for a host (or its parent domain), else the global switch.
    func allowsApps(forHost host: String?) -> Bool {
        guard let host = host.flatMap(ContentBlockingRules.normalizedHost) else { return openInApps }
        var candidate = host
        while true {
            if let value = siteOverrides[candidate] { return value }
            guard let dot = candidate.firstIndex(of: "."),
                  candidate[candidate.index(after: dot)...].contains(".")
            else { break }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
        return openInApps
    }
}

struct AppOpenPrompt: Equatable, Identifiable {
    let id = UUID()
    /// The app's name as the page named it (the scheme, capitalized).
    let appName: String
    /// What Open hands to the system; nil for a plain notice with no Open.
    let url: URL?
    /// A notice's own text (e.g. no app can open this page).
    var message: String?
}

enum LinkPolicy {
    enum Decision: Equatable {
        case allow
        /// Cancel, then load the same URL in this web view (skips Universal Links).
        case reloadInPlace
        /// Cancel and show the prompt; the person decides.
        case promptOpenApp(URL)
        /// Cancel and hand to the system at once (a tapped mailto:, or an
        /// app link while "Open links in apps" is on for the site).
        case openExternally(URL)
        case cancel
    }

    struct Navigation {
        var url: URL
        var targetIsMainFrame: Bool
        var isLinkActivated: Bool
        var httpMethod: String?
    }

    /// Schemes the system always handles from a tap, as before.
    static let systemSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]
    static let inPageSchemes: Set<String> = ["about", "blob", "data"]

    static func decide(_ nav: Navigation, settings: LinkSettings) -> Decision {
        let scheme = nav.url.scheme?.lowercased() ?? ""
        if inPageSchemes.contains(scheme) { return .allow }
        if scheme == "http" || scheme == "https" {
            let isGet = (nav.httpMethod ?? "GET").uppercased() == "GET"
            guard nav.targetIsMainFrame, nav.isLinkActivated, isGet else { return .allow }
            return settings.allowsApps(forHost: nav.url.host) ? .allow : .reloadInPlace
        }
        if scheme.isEmpty || scheme == "javascript" { return .cancel }
        if systemSchemes.contains(scheme) {
            return nav.isLinkActivated ? .openExternally(nav.url) : .cancel
        }
        // An app scheme (twitter://): never opened silently. A tap on a site
        // that is allowed to use apps opens at once; everything else asks.
        if nav.isLinkActivated, settings.openInApps { return .openExternally(nav.url) }
        return .promptOpenApp(nav.url)
    }

    static func appName(forScheme scheme: String?) -> String {
        guard let scheme, !scheme.isEmpty else { return "an app" }
        return scheme.prefix(1).uppercased() + scheme.dropFirst()
    }

    /// Safari's own user agent for this OS, so sites don't mistake the web
    /// view for an in-app browser (WKWebView's default has no Version/Safari).
    static func userAgent(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isPad: Bool
    ) -> String {
        let underscored = "\(osVersion.majorVersion)_\(osVersion.minorVersion)"
        let dotted = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        // iPad Safari asks for the desktop site, so it says Macintosh.
        let platform = isPad
            ? "Macintosh; Intel Mac OS X 10_15_7"
            : "iPhone; CPU iPhone OS \(underscored) like Mac OS X"
        let tail = isPad ? "Safari/605.1.15" : "Mobile/15E148 Safari/604.1"
        return "Mozilla/5.0 (\(platform)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(dotted) \(tail)"
    }
}

// MARK: - AppModel API for the UI

extension AppModel {
    var linkSettings: LinkSettings {
        LinkSettings(openInApps: settings.openLinksInApps, siteOverrides: settings.appLinkSiteOverrides)
    }

    /// Whether links to this page's site may open apps (override, else global).
    func opensApps(on url: URL?) -> Bool { linkSettings.allowsApps(forHost: url?.host) }

    /// The per-site switch. Matching the global setting clears the override.
    func setOpensApps(_ opens: Bool, on url: URL?) {
        guard let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) else { return }
        if opens == settings.openLinksInApps {
            settings.appLinkSiteOverrides[host] = nil
        } else {
            settings.appLinkSiteOverrides[host] = opens
        }
    }
}
