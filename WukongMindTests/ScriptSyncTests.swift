import Foundation
import WebKit
import XCTest
@testable import WukongMind

@MainActor
final class ScriptSyncTests: XCTestCase {
    private struct StubHTTPResponse: Sendable {
        var status = 200
        var body = Data()
        var delay: TimeInterval = 0
    }

    private final class LibraryStubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubHTTPResponse)?
        private static let lock = NSLock()

        static func install(_ next: @escaping @Sendable (URLRequest) -> StubHTTPResponse) {
            lock.withLock { handler = next }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let reply = Self.lock.withLock { Self.handler }?(request)
            guard let url = request.url, let reply else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            if reply.delay > 0 {
                Thread.sleep(forTimeInterval: reply.delay)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/javascript; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    struct Device {
        let app: AppModel
        let sync: CloudSyncController
        let transport: FakeCloudTransport
        let directory: URL
    }

    private var server: FakeCloudServer!

    override func setUp() async throws {
        server = FakeCloudServer()
    }

    private func makeDevice(stubHTTP: Bool = false) throws -> Device {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scriptsync-\(UUID().uuidString)", isDirectory: true)
        let keys = InMemoryProviderKeyStore([:])
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: keys)
        var snapshot = AppSnapshot()
        snapshot.settings.hasCompletedOnboarding = true
        try store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return launchDevice(directory: directory, stubHTTP: stubHTTP)
    }

    private func launchDevice(directory: URL, stubHTTP: Bool = false) -> Device {
        let keys = InMemoryProviderKeyStore([:])
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: keys)
        let transport = FakeCloudTransport(server: server, user: "user-1")
        let sync = CloudSyncController(
            transport: transport,
            files: CloudSyncFiles(directory: directory),
            defaults: nil,
            schedulesAutomatically: false
        )
        let app = AppModel(store: store, cloudSync: sync)
        app.browser.onPageContextChanged = nil
        if stubHTTP {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [LibraryStubProtocol.self]
            let client = AgentHTTPClient(
                configuration: config,
                pacer: ForumRequestPacer(clock: InstantPacingClock()),
                environment: AgentNetworkEnvironment(
                    cookies: { [] },
                    currentPageURL: { nil },
                    confirmBeforeWrites: { false },
                    pacing: { (false, .fast) },
                    isForumHost: { _ in false }
                )
            )
            app.scriptImporter.httpClientProvider = { client }
        }
        return Device(app: app, sync: sync, transport: transport, directory: directory)
    }

    private func sync(_ devices: Device...) async {
        for device in devices { await device.sync.performSync() }
    }

    private func writes(during body: () async -> Void) async -> Int {
        let before = server.writes
        await body()
        return server.writes - before
    }

    func testScriptSyncsInitialSeedAndSwitchStaysDeviceLocal() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)

        let enabledOnA = try a.app.scriptStore.create(
            id: "reader-mode",
            name: "Reader Mode",
            matchRules: ["https://forum.example.com/*"],
            js: "document.body.dataset.reader = '1';",
            css: "aside { display: none; }",
            isEnabled: true,
            source: .agent(userPrompt: "Clean up reader layout"),
            grants: ["GM_setValue", "GM_getValue"],
            now: t0
        )
        _ = try a.app.scriptStore.create(
            id: "muted-helper",
            name: "Muted Helper",
            matchRules: ["https://forum.example.com/*"],
            js: "console.log('off');",
            isEnabled: false,
            now: t0
        )
        try a.app.scriptStore.valuesStore.setValue(rawJSON: "\"sepia\"", forKey: "theme", scriptID: enabledOnA.id)

        await sync(a, b, a, b)

        let onB = try XCTUnwrap(b.app.scriptStore.script(id: "reader-mode"))
        XCTAssertEqual(onB.name, "Reader Mode")
        XCTAssertEqual(onB.js, "document.body.dataset.reader = '1';")
        XCTAssertEqual(onB.css, "aside { display: none; }")
        XCTAssertTrue(onB.isEnabled)
        XCTAssertEqual(onB.version, 1)
        XCTAssertTrue(onB.versions.isEmpty)
        XCTAssertNil(b.app.scriptStore.valuesStore.values(for: onB.id)["theme"])

        let offOnB = try XCTUnwrap(b.app.scriptStore.script(id: "muted-helper"))
        XCTAssertFalse(offOnB.isEnabled, "enabledSeed carries initial off state on first arrival")

        // Turning a script off (or auto-disabling after 3 error loads) stays local and sends nothing.
        _ = try a.app.scriptStore.setEnabled(id: "reader-mode", isEnabled: false)
        let toggleWrites = await writes { await self.sync(a, b) }
        XCTAssertEqual(toggleWrites, 0)
        XCTAssertEqual(a.sync.lastPassQueued, 0)
        XCTAssertTrue(try XCTUnwrap(b.app.scriptStore.script(id: "reader-mode")).isEnabled)

        for i in 1...3 {
            b.app.scriptStore.recordPageLoadError(scriptID: "reader-mode", message: "boom", loadID: "load-\(i)")
        }
        XCTAssertFalse(try XCTUnwrap(b.app.scriptStore.script(id: "reader-mode")).isEnabled)
        let errorWrites = await writes { await self.sync(b, a) }
        XCTAssertEqual(errorWrites, 0)
    }

    func testRemoteEditArrivesAsNewLocalVersionAndNextPassSendsNothing() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        let t1 = Date(timeIntervalSince1970: 1_760_001_000)
        let t2 = Date(timeIntervalSince1970: 1_760_002_000)

        _ = try a.app.scriptStore.create(
            id: "compact-list",
            name: "Compact List",
            matchRules: ["https://forum.example.com/*"],
            js: "document.body.dataset.v = '1';",
            source: .agent(userPrompt: "Compact rows"),
            now: t1
        )
        _ = try a.app.scriptStore.importUserScript(
            """
            // ==UserScript==
            // @name Imported Counter
            // @match https://forum.example.com/*
            // @version 2
            // @wukong-id imported-counter
            // ==/UserScript==
            console.log(1);
            """,
            now: t1
        )
        await sync(a, b, a, b)

        _ = try a.app.scriptStore.update(
            id: "compact-list",
            patch: ScriptUpdatePatch(js: "document.body.dataset.v = '2';"),
            origin: .editedByUser,
            now: t2
        )
        _ = try a.app.scriptStore.update(
            id: "imported-counter",
            patch: ScriptUpdatePatch(js: "console.log(2);"),
            origin: .editedByUser,
            now: t2
        )

        // Deliver A's edit to B.
        await sync(a, b)

        let bScript = try XCTUnwrap(b.app.scriptStore.script(id: "compact-list"))
        let aScript = try XCTUnwrap(a.app.scriptStore.script(id: "compact-list"))
        XCTAssertEqual(bScript.js, "document.body.dataset.v = '2';")
        XCTAssertEqual(bScript.version, 2)
        XCTAssertEqual(bScript.versions.count, 1)
        XCTAssertEqual(bScript.versionOrigin, .changedOnAnotherDevice)
        XCTAssertEqual(
            b.app.scriptStore.syncedContent(for: bScript),
            a.app.scriptStore.syncedContent(for: aScript)
        )
        XCTAssertFalse(b.app.scriptStore.syncedContent(for: bScript).contains("@wukong-enabled"))
        XCTAssertFalse(b.app.scriptStore.syncedContent(for: bScript).contains("@wukong-revision"))

        // Next sync pass on B (and A) must have nothing to send.
        let settleWrites = await writes { await self.sync(b, a) }
        XCTAssertEqual(settleWrites, 0)
        XCTAssertEqual(b.sync.lastPassQueued, 0)
        XCTAssertEqual(a.sync.lastPassQueued, 0)
        XCTAssertEqual(a.app.scriptStore.script(id: "compact-list")?.versions.count, 1)
        XCTAssertEqual(b.app.scriptStore.script(id: "compact-list")?.versions.count, 1)
    }

    func testConcurrentEditsKeepNewerTextArchiveLoserInHistoryAndSettleWithZeroWrites() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        let t0 = Date(timeIntervalSince1970: 1_760_010_000)
        let tOlder = Date(timeIntervalSince1970: 1_760_011_000)
        let tNewer = Date(timeIntervalSince1970: 1_760_012_000)

        _ = try a.app.scriptStore.create(
            id: "quote-fold",
            name: "Quote Fold",
            matchRules: ["https://forum.example.com/*"],
            js: "window.quoteFold = 'initial';",
            now: t0
        )
        await sync(a, b, a, b)

        _ = try a.app.scriptStore.update(
            id: "quote-fold",
            patch: ScriptUpdatePatch(js: "window.quoteFold = 'older-on-a';"),
            origin: .editedByUser,
            now: tOlder
        )
        _ = try b.app.scriptStore.update(
            id: "quote-fold",
            patch: ScriptUpdatePatch(js: "window.quoteFold = 'newer-on-b';"),
            origin: .editedByUser,
            now: tNewer
        )

        // B pushes newer edit, A merges and keeps its losing edit in History.
        await sync(b, a)

        let onA = try XCTUnwrap(a.app.scriptStore.script(id: "quote-fold"))
        let onB = try XCTUnwrap(b.app.scriptStore.script(id: "quote-fold"))
        XCTAssertEqual(onA.js, "window.quoteFold = 'newer-on-b';")
        XCTAssertEqual(onB.js, "window.quoteFold = 'newer-on-b';")
        XCTAssertEqual(onA.versionOrigin, .changedOnAnotherDevice)
        let replaced = try XCTUnwrap(onA.versions.first { $0.js == "window.quoteFold = 'older-on-a';" })
        XCTAssertEqual(replaced.origin, .replacedByAnotherDevice)

        // Next sync pass after replacing a local edit must send nothing.
        let settleWrites = await writes { await self.sync(a, b) }
        XCTAssertEqual(settleWrites, 0)
        XCTAssertEqual(a.sync.lastPassQueued, 0)
        XCTAssertEqual(b.sync.lastPassQueued, 0)
    }

    func testDeleteRemovesScriptOnBothDevices() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        _ = try a.app.scriptStore.create(
            id: "ephemeral",
            name: "Ephemeral",
            matchRules: ["https://forum.example.com/*"],
            js: "console.log('bye');",
            now: Date(timeIntervalSince1970: 1_760_020_000)
        )
        await sync(a, b, a, b)
        XCTAssertNotNil(b.app.scriptStore.script(id: "ephemeral"))

        try a.app.scriptStore.delete(id: "ephemeral")
        await sync(a, b)
        XCTAssertNil(a.app.scriptStore.script(id: "ephemeral"))
        XCTAssertNil(b.app.scriptStore.script(id: "ephemeral"))

        let settleWrites = await writes { await self.sync(b, a) }
        XCTAssertEqual(settleWrites, 0)
    }

    func testRequireLibraryVerifiedOnArrivalAndChangedHashKeepsScriptOff() async throws {
        let libCode = "window.__helperLoaded = 1;"
        let libData = Data(libCode.utf8)
        let libSHA = ScriptStore.sha256Hex(libData)
        let libURL = "https://cdn.example.org/helper.js"

        let a = try makeDevice(stubHTTP: true)
        let b = try makeDevice(stubHTTP: true)
        let c = try makeDevice(stubHTTP: true)

        var candidate = try UserScript.parseUserScriptFile(
            """
            // ==UserScript==
            // @name With Helper
            // @match https://forum.example.com/*
            // @require \(libURL)
            // ==/UserScript==
            window.__helperRan = window.__helperLoaded;
            """
        )
        candidate.id = "with-helper"
        let saved = try a.app.scriptStore.saveImportedScript(
            candidate,
            installURL: "https://greasyfork.example.org/scripts/with-helper.user.js",
            upstreamHash: "upstream-1",
            libraries: [ScriptLoadedLibrary(
                meta: ScriptRequiredLibrary(url: libURL, sha256: libSHA, sizeBytes: libData.count),
                code: libCode
            )],
            turnOn: true,
            now: Date(timeIntervalSince1970: 1_760_030_000)
        )

        // Device B fetches the matching library body -> verified and turned on.
        LibraryStubProtocol.install { _ in StubHTTPResponse(status: 200, body: libData) }
        await sync(a, b)
        await b.app.scriptStore.waitForPendingLibrarySyncs()

        let onB = try XCTUnwrap(b.app.scriptStore.script(id: saved.id))
        XCTAssertTrue(onB.isEnabled)
        XCTAssertNil(onB.disabledReason)
        XCTAssertEqual(b.app.scriptStore.loadVerifiedRequiredCode(for: onB), .success([libCode]))
        let bSettleWrites = await writes { await self.sync(b) }
        XCTAssertEqual(bSettleWrites, 0)

        // Device C receives the same script after the upstream library changed -> kept off with reason.
        LibraryStubProtocol.install { _ in StubHTTPResponse(status: 200, body: Data("window.__tampered = 1;".utf8)) }
        await sync(c)
        await c.app.scriptStore.waitForPendingLibrarySyncs()

        let onC = try XCTUnwrap(c.app.scriptStore.script(id: saved.id))
        XCTAssertFalse(onC.isEnabled)
        XCTAssertTrue(onC.disabledReason?.localizedCaseInsensitiveContains("hash") == true)
        let afterToggleAttempt = try c.app.scriptStore.setEnabled(id: saved.id, isEnabled: true)
        XCTAssertFalse(afterToggleAttempt.isEnabled, "unverified library must never turn on")
        await c.app.scriptStore.waitForPendingLibrarySyncs()
        XCTAssertFalse(try XCTUnwrap(c.app.scriptStore.script(id: saved.id)).isEnabled)
        let cSettleWrites = await writes { await self.sync(c) }
        XCTAssertEqual(cSettleWrites, 0)
    }

    func testRequireLibraryRecoversAfterTransientFetchFailureSyncPassToggleAndMidFetchKill() async throws {
        let libCode = "window.__retryHelper = 42;"
        let libData = Data(libCode.utf8)
        let libSHA = ScriptStore.sha256Hex(libData)
        let libURL = "https://cdn.example.org/retry-helper.js"

        let a = try makeDevice(stubHTTP: true)
        let b = try makeDevice(stubHTTP: true)
        let c = try makeDevice(stubHTTP: true)
        let d = try makeDevice(stubHTTP: true)

        var candidate = try UserScript.parseUserScriptFile(
            """
            // ==UserScript==
            // @name Retry Helper
            // @match https://forum.example.com/*
            // @require \(libURL)
            // ==/UserScript==
            window.__ran = window.__retryHelper;
            """
        )
        candidate.id = "retry-helper"
        let saved = try a.app.scriptStore.saveImportedScript(
            candidate,
            installURL: "https://greasyfork.example.org/scripts/retry-helper.user.js",
            upstreamHash: "upstream-retry-1",
            libraries: [ScriptLoadedLibrary(
                meta: ScriptRequiredLibrary(url: libURL, sha256: libSHA, sizeBytes: libData.count),
                code: libCode
            )],
            turnOn: true,
            now: Date(timeIntervalSince1970: 1_760_035_000)
        )

        // 1. Transient 500 on first arrival -> off with reason; next sync pass with 200 recovers & enables.
        LibraryStubProtocol.install { _ in StubHTTPResponse(status: 500, body: Data()) }
        await sync(a, b, c)
        await b.app.scriptStore.waitForPendingLibrarySyncs()
        await c.app.scriptStore.waitForPendingLibrarySyncs()

        let failedOnB = try XCTUnwrap(b.app.scriptStore.script(id: saved.id))
        XCTAssertFalse(failedOnB.isEnabled)
        XCTAssertNotNil(failedOnB.disabledReason)

        LibraryStubProtocol.install { _ in StubHTTPResponse(status: 200, body: libData) }
        let bRetryWrites = await writes { await self.sync(b) }
        await b.app.scriptStore.waitForPendingLibrarySyncs()
        XCTAssertEqual(bRetryWrites, 0)

        let recoveredOnB = try XCTUnwrap(b.app.scriptStore.script(id: saved.id))
        XCTAssertTrue(recoveredOnB.isEnabled, "enabledSeed preserved across transient library fetch failure")
        XCTAssertNil(recoveredOnB.disabledReason)
        XCTAssertEqual(b.app.scriptStore.loadVerifiedRequiredCode(for: recoveredOnB), .success([libCode]))
        _ = try b.app.scriptStore.setEnabled(id: saved.id, isEnabled: false)
        XCTAssertTrue(try b.app.scriptStore.setEnabled(id: saved.id, isEnabled: true).isEnabled)

        // 2. Manual setEnabled(true) retries without needing another sync pass.
        _ = try c.app.scriptStore.setEnabled(id: saved.id, isEnabled: true)
        await c.app.scriptStore.waitForPendingLibrarySyncs()
        let recoveredOnC = try XCTUnwrap(c.app.scriptStore.script(id: saved.id))
        XCTAssertTrue(recoveredOnC.isEnabled)
        XCTAssertNil(recoveredOnC.disabledReason)

        // 3. Killed mid-fetch: leaves explicit disabledReason on disk, then relaunch retries & turns on.
        LibraryStubProtocol.install { _ in StubHTTPResponse(status: 200, body: libData, delay: 0.4) }
        await sync(d)
        d.app.scriptStore.cancelPendingLibrarySyncsForTesting()
        let interruptedOnD = try XCTUnwrap(d.app.scriptStore.script(id: saved.id))
        XCTAssertFalse(interruptedOnD.isEnabled)
        XCTAssertNotNil(interruptedOnD.disabledReason, "interrupted mid-fetch script must not be silently off without a reason")

        LibraryStubProtocol.install { _ in StubHTTPResponse(status: 200, body: libData) }
        let dRelaunched = launchDevice(directory: d.directory, stubHTTP: true)
        await dRelaunched.app.scriptStore.waitForPendingLibrarySyncs()
        let recoveredOnD = try XCTUnwrap(dRelaunched.app.scriptStore.script(id: saved.id))
        XCTAssertTrue(recoveredOnD.isEnabled)
        XCTAssertNil(recoveredOnD.disabledReason)
    }

    func testOversizedScriptStaysLocalAndVerificationHoldsRemoteChange() async throws {
        let a = try makeDevice()
        let b = try makeDevice()
        let bigJS = "const payload = '" + String(repeating: "x", count: UserScript.maxSyncBytes + 128) + "';"
        let oversized = try a.app.scriptStore.create(
            id: "huge-script",
            name: "Huge Script",
            matchRules: ["https://forum.example.com/*"],
            js: bigJS,
            now: Date(timeIntervalSince1970: 1_760_040_000)
        )
        XCTAssertTrue(a.app.scriptStore.isOverSyncSizeLimit(oversized))

        let target = try a.app.scriptStore.create(
            id: "held-target",
            name: "Held Target",
            matchRules: ["https://forum.example.com/*"],
            js: "window.v = 1;",
            now: Date(timeIntervalSince1970: 1_760_040_000)
        )
        await sync(a, b, a, b)
        XCTAssertNil(b.app.scriptStore.script(id: "huge-script"))
        XCTAssertNil(server.records()[SyncRecord.recordName(kind: .script, id: "huge-script")])

        // Hold `held-target` on B inside candidate verification while A updates it.
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = ScriptWebController(webView: webView, store: b.app.scriptStore, agentBridge: AgentBridge(webView: webView))
        controller.beginCandidateVerification(target, replacingScriptID: target.id)

        _ = try a.app.scriptStore.update(
            id: target.id,
            patch: ScriptUpdatePatch(js: "window.v = 2;"),
            origin: .editedByUser,
            now: Date(timeIntervalSince1970: 1_760_041_000)
        )
        await sync(a, b)
        XCTAssertEqual(b.app.scriptStore.script(id: target.id)?.js, "window.v = 1;", "held while verifying")

        _ = controller.endCandidateVerification()
        await sync(b)
        XCTAssertEqual(b.app.scriptStore.script(id: target.id)?.js, "window.v = 2;")
        controller.detach()
    }

    func testOlderDecoderHoldsScriptRecordUntouchedAndUnsignedBuildDisablesCloudKit() async throws {
        // 1.3's SyncKind lacked `.script`, so decoding a `.script` payload fails and leaves the record held.
        enum SyncKindV1_3: String, Codable { case settings, forum, session, run, watched }
        struct SyncRecordV1_3: Codable { var format: Int; var kind: SyncKindV1_3; var id: String }

        let a = try makeDevice()
        _ = try a.app.scriptStore.create(
            id: "future-script",
            name: "Future Script",
            matchRules: ["https://forum.example.com/*"],
            js: "console.log('1.4');",
            now: Date(timeIntervalSince1970: 1_760_050_000)
        )
        await sync(a)

        let scriptName = SyncRecord.recordName(kind: .script, id: "future-script")
        let stored = try XCTUnwrap(server.records()[scriptName])
        let canonical = try SyncPayload.canonical(from: stored.payload)
        XCTAssertThrowsError(try SyncCoding.makeDecoder().decode(SyncRecordV1_3.self, from: canonical))

        // Engine seeing an unknown kind keeps it in `unreadable` without overwriting or deleting it,
        // matching how a 1.3 engine behaves when fetching a 1.4 `script` record.
        let futurePayload = Data("J{\"format\":1,\"kind\":\"futureKind\",\"id\":\"future-1\",\"fields\":{\"content\":\"x\"},\"stamps\":{}}".utf8)
        let unknownCloud = CloudRecord(
            recordName: "0123456789abcdef0123456789abcdef01234567",
            kind: "futureKind",
            formatVersion: 1,
            deletedAt: nil,
            payload: futurePayload,
            systemFields: nil
        )
        server.inject(unknownCloud)
        let b = try makeDevice()
        await sync(b)
        let idleWrites = await writes { await self.sync(b) }
        XCTAssertEqual(idleWrites, 0, "unreadable unknown-kind record must not be overwritten or tombstoned")
        guard case .error = b.sync.status else { return XCTFail("expected unreadable error, got \(b.sync.status)") }
        XCTAssertNotNil(b.app.scriptStore.script(id: "future-script"), "known records still sync cleanly alongside held unknown ones")
        XCTAssertNotNil(server.records()[unknownCloud.recordName], "unknown record left untouched on server")
        XCTAssertNil(server.records()[unknownCloud.recordName]?.deletedAt)

        // Unsigned / CloudKit-off build behaves as today.
        let unsignedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scriptsync-unsigned-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: unsignedDir) }
        let unsignedStore = PersistentStore(
            fileURL: unsignedDir.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore([:])
        )
        let unsignedSync = CloudSyncController(
            transport: nil,
            files: CloudSyncFiles(directory: unsignedDir),
            defaults: nil,
            schedulesAutomatically: false
        )
        let unsignedApp = AppModel(store: unsignedStore, cloudSync: unsignedSync)
        unsignedApp.browser.onPageContextChanged = nil
        XCTAssertEqual(unsignedSync.status, .unavailable("Sync needs a signed build"))
        _ = try unsignedApp.scriptStore.create(
            id: "local-only",
            name: "Local Only",
            matchRules: ["https://forum.example.com/*"],
            js: "console.log('ok');"
        )
        XCTAssertNotNil(unsignedApp.scriptStore.script(id: "local-only"))
    }
}
