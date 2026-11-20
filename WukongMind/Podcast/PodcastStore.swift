import Foundation

// MARK: - Read-aloud audio cache
//
// Cached read-aloud audio files live in `Caches/Podcasts/read-aloud/`.
// `reconcile` prunes read-aloud files older than 7 days and cleans up any
// leftover legacy episode folders.

final class PodcastStore {
    /// Cached audio older than this is deleted.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Read-aloud audio folder.
    static let readAloudFolder = "read-aloud"

    let directory: URL
    private let fileManager = FileManager.default

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Podcasts", isDirectory: true)
    }

    init(directory: URL = PodcastStore.defaultDirectory) {
        self.directory = directory
    }

    var readAloudDirectory: URL {
        directory.appendingPathComponent(Self.readAloudFolder, isDirectory: true)
    }

    /// Prunes read-aloud audio older than `maxAge` and removes any legacy
    /// episode directories.
    func reconcile(now: Date = Date()) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            if name == Self.readAloudFolder {
                pruneReadAloud(now: now)
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func deleteAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func pruneReadAloud(now: Date) {
        let folder = readAloudDirectory
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            if let date = modificationDate(of: url), now.timeIntervalSince(date) > Self.maxAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
