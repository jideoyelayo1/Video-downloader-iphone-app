import Foundation

enum StorageCleanup {
    static let autoDeleteKey = "deleteWatchedAfterDays"
    static let lastCleanupKey = "lastWatchedCleanup"
    static let cleanupTotalsKey = "watchedCleanupTotals"

    /// In days; 0 keeps watched videos.
    static let dayChoices = [0, 1, 3, 7, 14, 30]

    static func periodText(days: Int) -> String {
        if days % 7 == 0 { return days == 7 ? "1 week" : "\(days / 7) weeks" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    static func choiceName(days: Int) -> String {
        days > 0 ? "After " + periodText(days: days).capitalized : "Never"
    }

    /// Used for both the last cleanup and the running total since `date`.
    struct Cleanup: Codable, Equatable {
        var date: Date
        var count: Int
        var bytes: Int64
    }

    static func watched(_ items: [DownloadItem], olderThan days: Int, now: Date = Date()) -> [DownloadItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.status == .completed && ($0.watchedAt.map { $0 <= cutoff } ?? false) }
    }

    static func totalSize(_ items: [DownloadItem]) -> Int64 { items.reduce(0) { $0 + ($1.fileSize ?? 0) } }

    static func sizeText(_ items: [DownloadItem]) -> String {
        ByteCountFormatter.string(fromByteCount: totalSize(items), countStyle: .file)
    }

    static func freedText(_ item: DownloadItem) -> String {
        guard let size = item.fileSize, size > 0 else { return "It is removed from this iPhone." }
        return "It frees \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on this iPhone."
    }
}

/// An episode counts as watched when played to the end, through its credits, or closed in its last 10%.
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
    var finishedEpisodes: FinishedEpisodes {
        get { preferences.string(forKey: FinishedEpisodes.key).flatMap(FinishedEpisodes.init) ?? .keep }
        set {
            objectWillChange.send()
            preferences.set(newValue.rawValue, forKey: FinishedEpisodes.key)
        }
    }

    /// Also deletes episodes that are still downloading.
    func deleteShowAndEpisodes(_ show: Show) {
        guard let showStore else { return }
        let episodes = showStore.episodes(of: show)
        delete(episodes)
        showStore.delete(show)
        diagnostics?.record(event: "storage", url: "app://shows", note: "Deleted \(show.title) and its \(episodes.count) episodes")
    }

    /// 0 (the default) keeps watched videos.
    var deleteWatchedAfterDays: Int {
        get { max(preferences.integer(forKey: StorageCleanup.autoDeleteKey), 0) }
        set {
            objectWillChange.send()
            preferences.set(max(newValue, 0), forKey: StorageCleanup.autoDeleteKey)
        }
    }

    var lastCleanup: StorageCleanup.Cleanup? { cleanup(forKey: StorageCleanup.lastCleanupKey) }
    var cleanupTotals: StorageCleanup.Cleanup? { cleanup(forKey: StorageCleanup.cleanupTotalsKey) }

    private func cleanup(forKey key: String) -> StorageCleanup.Cleanup? {
        preferences.data(forKey: key).flatMap { try? JSONDecoder().decode(StorageCleanup.Cleanup.self, from: $0) }
    }

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

    func deleteWatchedVideos() {
        let watched = allItems().filter { $0.status == .completed && $0.isWatched }
        delete(watched)
        diagnostics?.record(event: "storage", url: "app://settings", note: "Deleted \(watched.count) watched videos")
    }
}
