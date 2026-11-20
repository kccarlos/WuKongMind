import XCTest
@testable import WukongMind

/// Every identifier derives from the one prefix the project generator sets.
final class AppIdentityTests: XCTestCase {
    func testIdentifiersDeriveFromTheBundlePrefix() {
        let prefix = AppIdentity.identifierPrefix
        XCTAssertEqual(prefix, Bundle.main.bundleIdentifier)
        XCTAssertEqual(AppIdentity.appGroupIdentifier, "group.\(prefix)")
        XCTAssertEqual(SharedInbox.appGroupIdentifier, AppIdentity.appGroupIdentifier)
        XCTAssertEqual(KeychainStore.providerKeysService, "\(prefix).provider-keys")
    }

    func testBackgroundTaskIdentifierIsPermittedInInfoPlist() {
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String]
        XCTAssertEqual(permitted, [WatchBackgroundRefresh.identifier, DigestBackgroundPrefetch.identifier])
        XCTAssertEqual(WatchBackgroundRefresh.identifier, "\(AppIdentity.identifierPrefix).watchRefresh")
        XCTAssertEqual(DigestBackgroundPrefetch.identifier, "\(AppIdentity.identifierPrefix).digestPrefetch")
    }

    func testOnlyTheWukongMindURLSchemeIsRegistered() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [IncomingLink.scheme])
        XCTAssertEqual(IncomingLink.scheme, "wukongmind")
    }

    func testSharedInboxDegradesGracefullyWhenAppGroupIsDisabled() {
        let previousOverride = SharedInbox.storageURLOverride
        SharedInbox.storageURLOverride = nil
        defer { SharedInbox.storageURLOverride = previousOverride }

        if !AppIdentity.isAppGroupEnabled {
            XCTAssertNil(SharedInbox.storageURL)
            XCTAssertEqual(SharedInbox.drainAll(), [])
        }
    }

    func testBackgroundModesMatchCloudKitCapability() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertEqual(modes.contains("remote-notification"), AppIdentity.isCloudKitEnabled)
    }

    func testPurposeStringsUseWebPageWording() {
        let keys = [
            "NSCameraUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSPhotoLibraryAddUsageDescription"
        ]
        for key in keys {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
            XCTAssertTrue(value.localizedCaseInsensitiveContains("web page"), "\(key) should mention web page: \(value)")
            XCTAssertFalse(value.localizedCaseInsensitiveContains("forum"), "\(key) should not mention forum: \(value)")
        }
    }
}
