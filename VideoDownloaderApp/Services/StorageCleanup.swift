import Foundation

/// Which watched videos to delete to save space.
enum StorageCleanup {
    static let autoDeleteKey = "deleteWatchedAfterDays"

    /// Completed videos watched at least `days` ago.
    static func watched(_ items: [DownloadItem], olderThan days: Int, now: Date = Date()) -> [DownloadItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.status == .completed && ($0.watchedAt.map { $0 <= cutoff } ?? false) }
    }

    static func totalSize(_ items: [DownloadItem]) -> Int64 { items.reduce(0) { $0 + ($1.fileSize ?? 0) } }

    static func sizeText(_ items: [DownloadItem]) -> String {
        ByteCountFormatter.string(fromByteCount: totalSize(items), countStyle: .file)
    }
}

extension DownloadManager {
    /// With the setting on, watched videos are deleted a week after they were watched.
    var deletesWatchedAfterAWeek: Bool {
        get { preferences.integer(forKey: StorageCleanup.autoDeleteKey) > 0 }
        set {
            objectWillChange.send()
            preferences.set(newValue ? 7 : 0, forKey: StorageCleanup.autoDeleteKey)
        }
    }

    /// Run at launch.
    @discardableResult
    func deleteOldWatchedVideos(now: Date = Date()) -> Int {
        let days = preferences.integer(forKey: StorageCleanup.autoDeleteKey)
        guard days > 0 else { return 0 }
        let old = StorageCleanup.watched(allItems(), olderThan: days, now: now)
        delete(old)
        if !old.isEmpty { diagnostics?.record(event: "storage", url: "app://cleanup", note: "Deleted \(old.count) videos watched over \(days) days ago") }
        return old.count
    }
}
