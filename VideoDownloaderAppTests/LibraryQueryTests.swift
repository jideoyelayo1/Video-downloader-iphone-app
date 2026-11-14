import XCTest
@testable import VideoDownloaderApp

final class LibraryQueryTests: XCTestCase {
    private let showPage = URL(string: "https://showsite.example/anime/vpoY93SPHAQZP9soq/p-1-dub")!

    private func video(_ title: String, downloaded: TimeInterval, size: Int64 = 100, page: URL? = nil) -> DownloadItem {
        let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                sourcePageURL: page ?? showPage, kind: .video, status: .completed,
                                createdAt: Date(timeIntervalSince1970: downloaded))
        item.completedAt = Date(timeIntervalSince1970: downloaded + 60)
        item.fileSize = size
        return item
    }

    private func titles(_ items: [DownloadItem]) -> [String] { items.map(\.displayTitle) }

    func testTitleOrderUsesEpisodeNumbers() {
        let items = [10, 2, 1, 12].map { video("Sample Show Ep. \($0) · Showsite", downloaded: Double($0)) }
        XCTAssertEqual(titles(LibraryQuery(sort: .title).apply(to: items)),
                       [1, 2, 10, 12].map { "Sample Show Ep. \($0)" })
    }

    func testDateSizeAndRecentlyWatchedOrders() {
        let old = video("Old", downloaded: 100, size: 900)
        let middle = video("Middle", downloaded: 200, size: 100)
        let new = video("New", downloaded: 300, size: 500)
        middle.lastPlayedAt = Date(timeIntervalSince1970: 1_000)
        old.lastPlayedAt = Date(timeIntervalSince1970: 500)
        let items = [middle, new, old]
        XCTAssertEqual(titles(LibraryQuery(sort: .newest).apply(to: items)), ["New", "Middle", "Old"])
        XCTAssertEqual(titles(LibraryQuery(sort: .oldest).apply(to: items)), ["Old", "Middle", "New"])
        XCTAssertEqual(titles(LibraryQuery(sort: .largest).apply(to: items)), ["Old", "New", "Middle"])
        XCTAssertEqual(titles(LibraryQuery(sort: .recentlyWatched).apply(to: items)), ["Middle", "Old", "New"], "never played last")
    }

    func testWatchedStatusFilters() {
        let watched = video("Watched", downloaded: 3)
        watched.setWatched(true)
        let started = video("Started", downloaded: 2)
        started.playbackPosition = 600
        let fresh = video("Fresh", downloaded: 1)
        let items = [watched, started, fresh]
        XCTAssertEqual(titles(LibraryQuery(status: .all).apply(to: items)), ["Watched", "Started", "Fresh"])
        XCTAssertEqual(titles(LibraryQuery(status: .unwatched).apply(to: items)), ["Started", "Fresh"])
        XCTAssertEqual(titles(LibraryQuery(status: .inProgress).apply(to: items)), ["Started"])
        XCTAssertEqual(titles(LibraryQuery(status: .watched).apply(to: items)), ["Watched"])
        XCTAssertFalse(LibraryQuery(status: .all).isFiltering)
        XCTAssertTrue(LibraryQuery(status: .watched).isFiltering)
    }

    func testLabelsFolderAndSearchCombine() {
        let anime = UUID(), favourite = UUID(), folder = UUID()
        let a = video("Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 9 · Showsite", downloaded: 3)
        a.labelIDs = [anime]
        let b = video("Sample Show Ep. 1 · Showsite", downloaded: 2)
        b.labelIDs = [anime, favourite]
        b.folderID = folder
        let c = video("Watch South Park (1997) S29E2 - Watch Series - Seriessite", downloaded: 1)
        let fragment = DownloadItem(title: "seg", remoteURL: URL(string: "https://cdn.example/seg-1.ts")!, sourcePageURL: showPage, kind: .video)
        let items = [a, b, c, fragment]
        XCTAssertEqual(LibraryQuery().apply(to: items).count, 3, "stream fragments never list")
        XCTAssertEqual(LibraryQuery(labelIDs: [favourite, UUID()]).apply(to: items).map(\.id), [b.id], "any chosen label matches")
        XCTAssertEqual(LibraryQuery(labelIDs: [anime]).apply(to: items).map(\.id), [a.id, b.id])
        XCTAssertEqual(LibraryQuery(labelIDs: [anime], folderID: folder).apply(to: items).map(\.id), [b.id])
        XCTAssertEqual(LibraryQuery(labelIDs: [anime], searchText: "re:zero").apply(to: items).map(\.id), [a.id])
        XCTAssertEqual(LibraryQuery(searchText: "Showsite").apply(to: items).count, 2, "search still finds the site in the full title")
    }

    func testSearchFindsAShowsEpisodesAndALabelsVideosByName() {
        let show = UUID(), label = UUID()
        let episode = video("Ep. 3", downloaded: 1)
        episode.showID = show
        let labelled = video("Clip", downloaded: 2)
        labelled.labelIDs = [label]
        let other = video("Something else", downloaded: 3)
        let names = [show: "Frieren", label: "Favourites"]
        XCTAssertEqual(titles(LibraryQuery(searchText: "frieren", names: names).apply(to: [episode, labelled, other])), ["Ep. 3"])
        XCTAssertEqual(titles(LibraryQuery(searchText: "favour", names: names).apply(to: [episode, labelled, other])), ["Clip"])
        XCTAssertEqual(titles(LibraryQuery(searchText: "else", names: names).apply(to: [episode, labelled, other])), ["Something else"])
    }

    func testMoviesAndVideosNotInAShow() {
        let show = UUID(), deletedShow = UUID()
        let episode = video("Episode", downloaded: 4)
        episode.showID = show
        let orphan = video("Orphan", downloaded: 3)
        orphan.showID = deletedShow
        let movie = video("Movie", downloaded: 2)
        movie.isMovie = true
        let loose = video("Loose", downloaded: 1)
        let items = [episode, orphan, movie, loose]
        XCTAssertEqual(titles(LibraryQuery(group: .movies).apply(to: items)), ["Movie"])
        XCTAssertEqual(titles(LibraryQuery(group: .notInShow, showIDs: [show]).apply(to: items)), ["Orphan", "Loose"],
                       "an episode of a deleted show needs a show too; movies don't")
        XCTAssertEqual(LibraryQuery(group: .all).apply(to: items).count, 4)
        XCTAssertTrue(LibraryQuery(group: .movies).isFiltering)
    }
}
