import Foundation

/// Which saved videos My Videos lists, and in what order.
struct LibraryQuery: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, title, recentlyWatched, largest

        var id: String { rawValue }
        var name: String {
            switch self {
            case .newest: "Newest Downloads"
            case .oldest: "Oldest Downloads"
            case .title: "Title"
            case .recentlyWatched: "Recently Watched"
            case .largest: "Largest"
            }
        }
    }

    enum Status: String, CaseIterable, Identifiable {
        case all, unwatched, inProgress, watched

        var id: String { rawValue }
        var name: String {
            switch self {
            case .all: "All Videos"
            case .unwatched: "Unwatched"
            case .inProgress: "In Progress"
            case .watched: "Watched"
            }
        }
    }

    var sort = Sort.newest
    var status = Status.all
    /// Videos with any of these labels.
    var labelIDs: Set<UUID> = []
    var folderID: UUID?
    var searchText = ""

    /// A status or label filter is narrowing the list (folders and search show themselves).
    var isFiltering: Bool { status != .all || !labelIDs.isEmpty }

    func matches(_ item: DownloadItem) -> Bool {
        guard !item.isStreamFragment else { return false }
        if let folderID, item.folderID != folderID { return false }
        if !searchText.isEmpty, !item.title.localizedStandardContains(searchText) { return false }
        if !labelIDs.isEmpty, !(item.labelIDs ?? []).contains(where: labelIDs.contains) { return false }
        switch status {
        case .all: return true
        case .unwatched: return !item.isWatched
        case .inProgress: return !item.isWatched && (item.playbackPosition ?? 0) > 10
        case .watched: return item.isWatched
        }
    }

    func apply(to items: [DownloadItem]) -> [DownloadItem] {
        items.filter(matches).sorted(by: areInOrder)
    }

    private func areInOrder(_ a: DownloadItem, _ b: DownloadItem) -> Bool {
        let downloadedA = a.completedAt ?? a.createdAt, downloadedB = b.completedAt ?? b.createdAt
        switch sort {
        case .newest:
            return downloadedA > downloadedB
        case .oldest:
            return downloadedA < downloadedB
        case .title:
            // Numbers compare by value, so "Ep. 2" comes before "Ep. 10".
            let order = a.displayTitle.localizedStandardCompare(b.displayTitle)
            return order == .orderedSame ? downloadedA > downloadedB : order == .orderedAscending
        case .recentlyWatched:
            let playedA = a.lastPlayedAt ?? .distantPast, playedB = b.lastPlayedAt ?? .distantPast
            return playedA == playedB ? downloadedA > downloadedB : playedA > playedB
        case .largest:
            let sizeA = a.fileSize ?? 0, sizeB = b.fileSize ?? 0
            return sizeA == sizeB ? downloadedA > downloadedB : sizeA > sizeB
        }
    }
}
