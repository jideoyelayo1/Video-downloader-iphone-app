import XCTest
@testable import VideoDownloaderApp

@MainActor
final class LibraryStatsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func video(_ title: String, site: String = "***REMOVED***.to", size: Int64? = 100, status: DownloadStatus = .completed,
                       watched: Bool = false, position: Double? = nil, show: Show? = nil, daysAgo: Double = 30) -> DownloadItem {
        let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                sourcePageURL: URL(string: "https://\(site)/watch")!, kind: .video, status: status,
                                createdAt: now.addingTimeInterval(-daysAgo * 86_400))
        item.fileSize = size
        item.watchedAt = watched ? now : nil
        item.playbackPosition = position
        item.showID = show?.id
        return item
    }

    func testCountsAndSizes() {
        let show = Show(title: "Fixture Show")
        let items = [
            video("Ep. 1", size: 300, watched: true, show: show),
            video("Ep. 2", size: 300, position: 120, show: show, daysAgo: 2),
            video("Film", site: "www.***REMOVED***.to", size: 500),
            video("Barely started", site: "***REMOVED***.to", size: 50, position: 5),
            video("Downloading", size: nil, status: .downloading, daysAgo: 0),
            video("Failed", size: nil, status: .failed)
        ]
        let stats = LibraryStats(items: items, shows: [show], now: now)

        XCTAssertEqual(stats.videos, 4, "only finished downloads count")
        XCTAssertEqual(stats.watched, 1)
        XCTAssertEqual(stats.unwatched, 3)
        XCTAssertEqual(stats.inProgress, 1, "a few seconds in isn't in progress, as in the filter")
        XCTAssertEqual(stats.bytes, 1_150)
        XCTAssertEqual(stats.watchedBytes, 300)
        XCTAssertEqual(stats.unwatchedBytes, 850)
        XCTAssertEqual(stats.addedThisWeek, 1)
        XCTAssertEqual(stats.addedThisWeekBytes, 300)

        XCTAssertEqual(stats.shows.map(\.name), ["Fixture Show"])
        XCTAssertEqual(stats.shows.first?.count, 2)
        XCTAssertEqual(stats.shows.first?.bytes, 600)
        XCTAssertEqual(stats.notInShow.count, 2)
        XCTAssertEqual(stats.notInShow.bytes, 550)

        XCTAssertEqual(stats.sites.map(\.name), ["***REMOVED***", "***REMOVED***"], "largest first, with www. folded in")
        XCTAssertEqual(stats.sites.map(\.count), [2, 2])
        XCTAssertEqual(stats.sites.map(\.bytes), [600, 550])
    }

    func testShowsAreLargestFirstAndDeletedShowsDontCount() {
        let small = Show(title: "A Small Show"), large = Show(title: "Z Large Show"), empty = Show(title: "Followed, No Episodes")
        let deleted = Show(title: "Deleted")
        let items = [video("S1", size: 100, show: small), video("L1", size: 400, show: large), video("Orphan", size: 10, show: deleted)]
        let stats = LibraryStats(items: items, shows: [small, large, empty], now: now)
        XCTAssertEqual(stats.shows.map(\.name), ["Z Large Show", "A Small Show"], "shows without saved episodes aren't listed")
        XCTAssertEqual(stats.notInShow.count, 1, "an episode of a show that's gone counts as not in a show")
    }

    func testMoviesAreCountedApartFromVideosNotInAShow() {
        let film = video("Film", size: 700)
        film.isMovie = true
        let stats = LibraryStats(items: [film, video("Clip", size: 20)], shows: [], now: now)
        XCTAssertEqual(stats.movies.count, 1)
        XCTAssertEqual(stats.movies.bytes, 700)
        XCTAssertEqual(stats.notInShow.count, 1, "as in My Videos, a movie isn't counted as not in a show")
    }

    func testMeasuredSizesFillInOlderVideos() {
        let older = video("Older", size: nil)
        let stats = LibraryStats(items: [older, video("Newer", size: 200)], shows: [], sizes: [older.id: 1_000], now: now)
        XCTAssertEqual(stats.bytes, 1_200)
        XCTAssertEqual(LibraryStats(items: [older], shows: [], now: now).bytes, 0, "unmeasured and unrecorded counts as nothing")
    }
}
