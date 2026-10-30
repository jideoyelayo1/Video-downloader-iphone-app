import Foundation

/// What the library holds and the space it takes, for Settings.
struct LibraryStats: Equatable {
    /// Saved videos of one show or from one site.
    struct Group: Equatable, Identifiable {
        let id: String
        let name: String
        let count: Int
        let bytes: Int64
    }

    var videos = 0
    var watched = 0
    /// Started but not finished, as the In Progress filter counts them.
    var inProgress = 0
    var bytes: Int64 = 0
    var watchedBytes: Int64 = 0
    var addedThisWeek = 0
    var addedThisWeekBytes: Int64 = 0
    /// Shows with saved episodes, largest first.
    var shows: [Group] = []
    /// Videos marked as movies, which My Videos keeps out of Not in a Show.
    var movies = Group(id: "movies", name: "Movies", count: 0, bytes: 0)
    /// Videos that aren't episodes of a show or movies.
    var notInShow = Group(id: "notInShow", name: "Not in a show", count: 0, bytes: 0)
    /// Largest first.
    var sites: [Group] = []

    var unwatched: Int { videos - watched }
    var unwatchedBytes: Int64 { bytes - watchedBytes }

    /// - Parameter sizes: measured sizes of videos saved before sizes were recorded.
    init(items: [DownloadItem], shows: [Show], sizes: [UUID: Int64] = [:], now: Date = Date()) {
        let completed = items.filter { $0.status == .completed }
        func size(_ item: DownloadItem) -> Int64 { item.fileSize ?? sizes[item.id] ?? 0 }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let inProgressQuery = LibraryQuery(status: .inProgress)
        for item in completed {
            let itemBytes = size(item)
            videos += 1
            bytes += itemBytes
            if item.isWatched {
                watched += 1
                watchedBytes += itemBytes
            } else if inProgressQuery.matches(item) {
                inProgress += 1
            }
            if (item.completedAt ?? item.createdAt) >= weekAgo {
                addedThisWeek += 1
                addedThisWeekBytes += itemBytes
            }
        }

        let showsByID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(grouping: completed) { $0.showID.flatMap { showsByID[$0] }?.id }
        self.shows = Self.largestFirst(episodes.compactMap { id, items in
            id.flatMap { showsByID[$0] }.map { Group(id: $0.id.uuidString, name: $0.title, count: items.count, bytes: items.reduce(0) { $0 + size($1) }) }
        })
        let movieItems = completed.filter(\.isMovie)
        movies = Group(id: movies.id, name: movies.name, count: movieItems.count, bytes: movieItems.reduce(0) { $0 + size($1) })
        let loose = (episodes[UUID?.none] ?? []).filter { !$0.isMovie }
        notInShow = Group(id: notInShow.id, name: notInShow.name, count: loose.count, bytes: loose.reduce(0) { $0 + size($1) })

        let bySite = Dictionary(grouping: completed) { $0.sourcePageURL.host.map(SiteNames.name(for:)) ?? "Other" }
        sites = Self.largestFirst(bySite.map { name, items in
            Group(id: name, name: name, count: items.count, bytes: items.reduce(0) { $0 + size($1) })
        })
    }

    private static func largestFirst(_ groups: [Group]) -> [Group] {
        groups.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }
}
