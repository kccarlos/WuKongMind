import Foundation

// MARK: - Feedback reports

/// Task exports saved for TestFlight feedback (docs/wukongmind/feedback.md): ⋯ › Report a problem,
/// and a task that ends in an error when Settings › Agent › Developer › "Save failed tasks for
/// feedback" is on. They go to the iCloud Drive container's `Documents/Reports/`, which reaches the
/// owner's Mac by itself; without iCloud, to the app's own `Documents/Reports/` (Files app).
enum FeedbackReportLocation: Equatable, Sendable {
    case iCloud
    case local
}

struct FeedbackReportSaveResult: Equatable, Sendable {
    var url: URL
    var location: FeedbackReportLocation
}

struct FeedbackReportStore: Sendable {
    /// Reports kept; older ones are deleted after each save.
    static let maxReports = 50
    /// Past this many bytes in total the oldest reports go too (the newest always stays). Local
    /// reports share `Documents/` with the Agent's workspace and its 1 GB cap.
    static let maxTotalBytes: Int64 = 200 * 1024 * 1024
    static let folderName = "Reports"

    /// The ubiquity container's root, or nil without iCloud. Called off the main thread.
    var ubiquityContainer: @Sendable () -> URL?
    /// The app's `Documents/` folder (the fallback's parent).
    var localDocuments: URL

    static var live: FeedbackReportStore {
        FeedbackReportStore(ubiquityContainer: systemUbiquityContainer, localDocuments: AgentWorkspace.defaultRoot)
    }

    /// The first container in `com.apple.developer.ubiquity-container-identifiers`: only in a build
    /// generated with `DC_ENABLE_CLOUDKIT=YES` and with someone signed in to iCloud.
    @Sendable static func systemUbiquityContainer() -> URL? {
        #if CLOUDKIT_ENABLED
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        return FileManager.default.url(forUbiquityContainerIdentifier: nil)
        #else
        return nil
        #endif
    }

    // MARK: Names

    /// `<ISO-time>-<host>-task.json`, the time in UTC in ISO 8601 basic format
    /// (`20261117T093012Z`), so the names sort by time and carry no colons.
    static func filename(date: Date, host: String?, attempt: Int = 1) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let counter = attempt > 1 ? "-\(attempt)" : ""
        return "\(formatter.string(from: date))-\(sanitizedHost(host))-task\(counter).json"
    }

    /// Lowercased letters, digits, dots and dashes; "no-page" when the task had no page.
    static func sanitizedHost(_ host: String?) -> String {
        let mapped = (host ?? "").lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
                ? character : "-"
        }
        let trimmed = String(mapped.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return trimmed.isEmpty ? "no-page" : trimmed
    }

    /// A report's own name, from a file name in the folder: iCloud keeps a file that isn't
    /// downloaded as `.<name>.icloud`. Nil for anything that isn't a report.
    static func reportName(_ fileName: String) -> String? {
        var name = fileName
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(".icloud".count))
        }
        let pattern = #"^\d{8}T\d{6}Z-.+-task(-\d+)?\.json$"#
        return name.range(of: pattern, options: .regularExpression) != nil ? name : nil
    }

    // MARK: Save and prune

    /// Where reports go now: the iCloud container when there is one, else local `Documents/`.
    func reportsFolder() -> (url: URL, location: FeedbackReportLocation) {
        if let container = ubiquityContainer() {
            return (container.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(Self.folderName, isDirectory: true), .iCloud)
        }
        return (localDocuments.appendingPathComponent(Self.folderName, isDirectory: true), .local)
    }

    /// Writes the report and prunes the folder. A failed iCloud write falls back to local
    /// `Documents/Reports/`; only a failed local write throws.
    func save(data: Data, date: Date = Date(), host: String?) throws -> FeedbackReportSaveResult {
        let target = reportsFolder()
        if target.location == .iCloud, let url = try? write(data, in: target.url, date: date, host: host) {
            prune(folder: target.url)
            return .init(url: url, location: .iCloud)
        }
        let local = localDocuments.appendingPathComponent(Self.folderName, isDirectory: true)
        let url = try write(data, in: local, date: date, host: host)
        prune(folder: local)
        return .init(url: url, location: .local)
    }

    private func write(_ data: Data, in folder: URL, date: Date, host: String?) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var attempt = 1
        var url = folder.appendingPathComponent(Self.filename(date: date, host: host))
        while fileManager.fileExists(atPath: url.path) {
            attempt += 1
            url = folder.appendingPathComponent(Self.filename(date: date, host: host, attempt: attempt))
        }
        try coordinate(writingAt: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
        return url
    }

    /// Keeps the newest `maxReports` reports (and at most `maxTotalBytes`); deletes the rest.
    /// Files that aren't reports are left alone.
    func prune(folder: URL, keep: Int = FeedbackReportStore.maxReports, maxBytes: Int64 = FeedbackReportStore.maxTotalBytes) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else { return }
        let reports = urls.compactMap { url in Self.reportName(url.lastPathComponent).map { (name: $0, url: url) } }
            .sorted { $0.name > $1.name }
        var total: Int64 = 0
        for (index, report) in reports.enumerated() {
            let size = Int64((try? report.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            total += size
            if index >= keep || (index > 0 && total > maxBytes) {
                try? coordinate(writingAt: report.url, options: .forDeleting) { try fileManager.removeItem(at: $0) }
            }
        }
    }

    private func coordinate(
        writingAt url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) {
            do { try body($0) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    // MARK: When a task saves itself

    /// A task that ended in an error saves its export when the setting is on: an API or network
    /// error (`.failed`) and the step limit. Completed and stopped runs don't; a declined
    /// confirmation goes back to the model as a tool result and doesn't end the run.
    static func savesAutomatically(after state: BrowserAgentRunState, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch state {
        case .failed, .stepLimitReached: return true
        case .idle, .running, .completed, .stopped: return false
        }
    }
}
