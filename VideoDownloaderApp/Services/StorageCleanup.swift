import Foundation

/// Which watched videos to delete to save space.
enum StorageCleanup {
    static let autoDeleteKey = "deleteWatchedAfterDays"
    static let lastCleanupKey = "lastWatchedCleanup"
    static let cleanupTotalsKey = "watchedCleanupTotals"

    /// The choices in Settings, in days; 0 keeps watched videos.
    static let dayChoices = [0, 1, 3, 7, 14, 30]

    /// "1 day", "3 days", "1 week", "2 weeks".
    static func periodText(days: Int) -> String {
        if days % 7 == 0 { return days == 7 ? "1 week" : "\(days / 7) weeks" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "Never", "After 3 Days", "After 1 Week".
    static func choiceName(days: Int) -> String {
        days > 0 ? "After " + periodText(days: days).capitalized : "Never"
    }

    /// What automatic cleanups deleted: the last one, or all of them since `date`.
    struct Cleanup: Codable, Equatable {
        var date: Date
        var count: Int
        var bytes: Int64
    }

    /// Completed videos watched at least `days` ago.
    static func watched(_ items: [DownloadItem], olderThan days: Int, now: Date = Date()) -> [DownloadItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.status == .completed && ($0.watchedAt.map { $0 <= cutoff } ?? false) }
    }

    static func totalSize(_ items: [DownloadItem]) -> Int64 { items.reduce(0) { $0 + ($1.fileSize ?? 0) } }

    static func sizeText(_ items: [DownloadItem]) -> String {
        ByteCountFormatter.string(fromByteCount: totalSize(items), countStyle: .file)
    }

    /// "It frees 350 MB on this iPhone.", for a question about deleting the video.
    static func freedText(_ item: DownloadItem) -> String {
        guard let size = item.fileSize, size > 0 else { return "It is removed from this iPhone." }
        return "It frees \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on this iPhone."
    }
}

/// What happens to an episode of a show once it has been watched in the player: played to the
/// end, through to its marked credits, or closed in its last 10%.
enum FinishedEpisodes: String, CaseIterable, Identifiable {
    case keep, ask, delete

    static let key = "finishedEpisodes"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .keep: "Never"
        case .ask: "Ask First"
        case .delete: "Automatically"
        }
    }
}

extension DownloadManager {
    /// Off unless chosen in Downloads.
    var finishedEpisodes: FinishedEpisodes {
        get { preferences.string(forKey: FinishedEpisodes.key).flatMap(FinishedEpisodes.init) ?? .keep }
        set {
            objectWillChange.send()
            preferences.set(newValue.rawValue, forKey: FinishedEpisodes.key)
        }
    }

    /// Deletes the show and its episodes' videos, including any still downloading.
    func deleteShowAndEpisodes(_ show: Show) {
        guard let showStore else { return }
        let episodes = showStore.episodes(of: show)
        delete(episodes)
        showStore.delete(show)
        diagnostics?.record(event: "storage", url: "app://shows", note: "Deleted \(show.title) and its \(episodes.count) episodes")
    }

    /// Watched videos are deleted this many days after they were watched; 0 (the default) keeps them.
    var deleteWatchedAfterDays: Int {
        get { max(preferences.integer(forKey: StorageCleanup.autoDeleteKey), 0) }
        set {
            objectWillChange.send()
            preferences.set(max(newValue, 0), forKey: StorageCleanup.autoDeleteKey)
        }
    }

    var lastCleanup: StorageCleanup.Cleanup? { cleanup(forKey: StorageCleanup.lastCleanupKey) }
    /// Every automatic cleanup since the first.
    var cleanupTotals: StorageCleanup.Cleanup? { cleanup(forKey: StorageCleanup.cleanupTotalsKey) }

    private func cleanup(forKey key: String) -> StorageCleanup.Cleanup? {
        preferences.data(forKey: key).flatMap { try? JSONDecoder().decode(StorageCleanup.Cleanup.self, from: $0) }
    }

    /// Run at launch.
    @discardableResult
    func deleteOldWatchedVideos(now: Date = Date()) -> Int {
        let days = deleteWatchedAfterDays
        guard days > 0 else { return 0 }
        let old = StorageCleanup.watched(allItems(), olderThan: days, now: now)
        guard !old.isEmpty else { return 0 }
        let bytes = StorageCleanup.totalSize(old)
        delete(old)
        let last = StorageCleanup.Cleanup(date: now, count: old.count, bytes: bytes)
        var totals = cleanupTotals ?? StorageCleanup.Cleanup(date: now, count: 0, bytes: 0)
        totals.count += old.count
        totals.bytes += bytes
        objectWillChange.send()
        preferences.set(try? JSONEncoder().encode(last), forKey: StorageCleanup.lastCleanupKey)
        preferences.set(try? JSONEncoder().encode(totals), forKey: StorageCleanup.cleanupTotalsKey)
        diagnostics?.record(event: "storage", url: "app://cleanup", note: "Deleted \(old.count) videos watched over \(StorageCleanup.periodText(days: days)) ago")
        return old.count
    }

    /// Deletes every watched video, from Settings.
    func deleteWatchedVideos() {
        let watched = allItems().filter { $0.status == .completed && $0.isWatched }
        delete(watched)
        diagnostics?.record(event: "storage", url: "app://settings", note: "Deleted \(watched.count) watched videos")
    }
}
