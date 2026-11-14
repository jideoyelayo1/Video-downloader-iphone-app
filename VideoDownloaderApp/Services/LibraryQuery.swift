import Foundation

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

    enum Group: String, CaseIterable, Identifiable {
        case all, movies, notInShow

        var id: String { rawValue }
        var name: String {
            switch self {
            case .all: "All Videos"
            case .movies: "Movies"
            case .notInShow: "Not in a Show"
            }
        }
        var systemImage: String {
            switch self {
            case .all: "play.rectangle"
            case .movies: "film"
            case .notInShow: "rectangle.stack.badge.plus"
            }
        }
    }

    var sort = Sort.newest
    var status = Status.all
    var group = Group.all
    /// Shows that exist, so an episode of a deleted show counts as not in a show.
    var showIDs: Set<UUID> = []
    var labelIDs: Set<UUID> = []
    var folderID: UUID?
    var searchText = ""
    /// Show and label names by ID, so searching a show's or label's name finds its videos.
    var names: [UUID: String] = [:]

    /// Folders and search aren't counted because they show themselves.
    var isFiltering: Bool { status != .all || !labelIDs.isEmpty || group != .all }

    func matches(_ item: DownloadItem) -> Bool {
        guard !item.isStreamFragment else { return false }
        if let folderID, item.folderID != folderID { return false }
        if !searchText.isEmpty {
            let related = ([item.showID].compactMap { $0 } + (item.labelIDs ?? [])).compactMap { names[$0] }
            guard ([item.title] + related).contains(where: { $0.localizedStandardContains(searchText) }) else { return false }
        }
        if !labelIDs.isEmpty, !(item.labelIDs ?? []).contains(where: labelIDs.contains) { return false }
        switch group {
        case .all: break
        case .movies: if !item.isMovie { return false }
        case .notInShow: if item.isMovie || item.showID.map(showIDs.contains) == true { return false }
        }
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
