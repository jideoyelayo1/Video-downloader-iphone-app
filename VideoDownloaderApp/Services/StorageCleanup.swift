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
