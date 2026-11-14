import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class ShowTests: XCTestCase {
    /// The titles of a real library (2026-10-02), as their sites named them.
    private let libraryTitles = [
        "Mushoku Tensei III: Isekai Ittara Honki Dasu Ep. 14 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 1 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 2 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 3 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 4 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 5 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 12 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 13 · Showsite",
        "Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 9 · Showsite",
        "Sample Show Ep. 1 · Showsite",
        "Sample Show Ep. 10 · Showsite",
        "Sample Show Ep. 2 · Showsite",
        "Sample Show Ep. 3 · Showsite",
        "Watch South Park (1997) S29E2 - Watch Series - Seriessite",
    ]
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try LibrarySchema.container(inMemory: true)
    }

    private func video(_ title: String) -> DownloadItem {
        let page = title.hasSuffix("Seriessite") ? "https://seriessite.example/watch/tv/2190" : "https://showsite.example/anime/x/p-1-dub"
        let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                sourcePageURL: URL(string: page)!, kind: .video, status: .completed)
        container.mainContext.insert(item)
        return item
    }

    func testShowPagesSplitIntoSeasonsOnlyWhenEveryTitleNamesOne() {
        let seasons = ["South Park S1E1", "South Park S1E2", "South Park S2E1"].map(video)
        XCTAssertEqual(ShowPlaylist.seasonRuns(seasons), [.init(season: 1, range: 0..<2), .init(season: 2, range: 2..<3)])
        XCTAssertEqual(ShowPlaylist.seasonRuns(Array(seasons.prefix(2))), [.init(season: nil, range: 0..<2)], "one season needs no headers")
        let mixed = [video("South Park S1E1"), video("South Park Ep. 2")]
        XCTAssertEqual(ShowPlaylist.seasonRuns(mixed), [.init(season: nil, range: 0..<2)])
        XCTAssertEqual(ShowPlaylist.seasonRuns([]), [.init(season: nil, range: 0..<0)])
    }

    func testSeriesAndEpisodeNumbersFromTitles() {
        func parse(_ title: String) -> ShowSuggestion.Parsed { ShowSuggestion.parse(title) }
        XCTAssertEqual(parse("Sample Show Ep. 10"), .init(series: "Sample Show", season: nil, episode: 10))
        XCTAssertEqual(parse("Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 9").series, "Re:Zero kara Hajimeru Isekai Seikatsu Season 2")
        XCTAssertEqual(parse("Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 1"),
                       .init(series: "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2", season: nil, episode: 1))
        XCTAssertEqual(parse("Mushoku Tensei III: Isekai Ittara Honki Dasu Ep. 14").series, "Mushoku Tensei III: Isekai Ittara Honki Dasu")
        XCTAssertEqual(parse("Watch South Park (1997) S29E2 - Watch Series"), .init(series: "South Park (1997)", season: 29, episode: 2))
        XCTAssertEqual(parse("Frieren - Episode 5"), .init(series: "Frieren", season: nil, episode: 5))
        XCTAssertEqual(parse("Basic Video Page").episode, nil)
        XCTAssertEqual(parse("Movie 1997").episode, nil, "a year isn't an episode")
    }

    func testSuggestionsGroupSeriesInEpisodeOrder() {
        libraryTitles.forEach { _ = video($0) }
        let items = try! container.mainContext.fetch(FetchDescriptor<DownloadItem>())
        let suggestions = ShowSuggestion.suggestions(items: items, shows: [], dismissed: [])
        XCTAssertEqual(suggestions.map(\.series), ["Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2", "Sample Show",
                                                   "Re:Zero kara Hajimeru Isekai Seikatsu Season 2"],
                       "single episodes (Mushoku Tensei, South Park) aren't suggested")
        XCTAssertEqual(suggestions[1].items.map(\.displayTitle), [1, 2, 3, 10].map { "Sample Show Ep. \($0)" })
        XCTAssertEqual(suggestions[2].items.map(\.displayTitle).map { ShowSuggestion.parse($0).episode }, [9, 12, 13])

        let dismissed = ShowSuggestion.suggestions(items: items, shows: [], dismissed: [suggestions[0].key])
        XCTAssertEqual(dismissed.count, 2, "Not Now hides a suggestion")
    }

    func testShowsKeepTheViewersOrderAndSuggestNewEpisodes() throws {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        let episodes = [3, 1, 2].map { video("Sample Show Ep. \($0) · Showsite") }
        let show = store.create(title: "Sample Show", with: ShowSuggestion.inEpisodeOrder(episodes))
        func order() -> [Int?] { store.episodes(of: show).map { ShowSuggestion.parse($0.displayTitle).episode } }
        XCTAssertEqual(order(), [1, 2, 3])

        store.move(in: show, from: [2], to: 0)
        XCTAssertEqual(order(), [3, 1, 2], "dragged into the viewer's own order")
        store.orderByEpisodeNumber(show)
        XCTAssertEqual(order(), [1, 2, 3])

        let fourth = video("Sample Show Ep. 4 · Showsite")
        let suggestion = try XCTUnwrap(store.suggestions.first)
        XCTAssertTrue(suggestion.existingShow === show)
        XCTAssertEqual(suggestion.items.map(\.id), [fourth.id])
        store.add(suggestion.items, to: show)
        XCTAssertEqual(order(), [1, 2, 3, 4])
        XCTAssertTrue(store.suggestions.isEmpty)

        let all = store.episodes(of: show)
        XCTAssertEqual(ShowPlaylist.next(after: all[1], in: all)?.id, all[2].id)
        XCTAssertNil(ShowPlaylist.next(after: all[3], in: all))
        all[0].setWatched(true)
        all[1].playbackPosition = 300
        XCTAssertEqual(ShowPlaylist.upNext(in: all)?.id, all[1].id, "the first episode not yet watched")

        store.remove(all[1])
        XCTAssertEqual(order(), [1, 3, 4])
        XCTAssertEqual(store.episodes(of: show).map(\.showOrder), [0, 1, 2], "renumbered")
        store.delete(show)
        XCTAssertTrue(all.allSatisfy { $0.showID == nil && $0.showOrder == nil }, "the videos stay, outside any show")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<DownloadItem>()).count, 4)
    }

    func testContinueWatchingOffersTheNextEpisodeOfAFinishedOne() throws {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        let episodes = [1, 2, 3].map { video("Sample Show Ep. \($0) · Showsite") }
        store.create(title: "Sample Show", with: episodes)
        let other = video("Mushoku Tensei III: Isekai Ittara Honki Dasu Ep. 14 · Showsite")
        other.playbackPosition = 300
        other.lastPlayedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ShowPlaylist.continueWatching([other] + episodes).map(\.id), [other.id], "nothing of the show played yet")

        episodes[0].lastPlayedAt = Date(timeIntervalSince1970: 2_000)
        episodes[0].setWatched(true)
        XCTAssertEqual(ShowPlaylist.continueWatching([other] + episodes).map(\.id), [episodes[1].id, other.id],
                       "episode 2 follows the finished episode 1, most recent first")

        episodes[1].lastPlayedAt = Date(timeIntervalSince1970: 3_000)
        episodes[1].playbackPosition = 120
        XCTAssertEqual(ShowPlaylist.continueWatching([other] + episodes).map(\.id), [episodes[1].id, other.id], "now in progress, listed once")
    }

    /// Delete Finished Episodes removes the episode Continue Watching follows on from; the show remembers it.
    func testContinueWatchingOffersTheEpisodeAfterADeletedOne() throws {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        let downloads = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        downloads.showStore = store
        let episodes = [1, 2, 3].map { video("Sample Show Ep. \($0) · Showsite") }
        let show = store.create(title: "Sample Show", with: episodes)
        let other = video("Mushoku Tensei III: Isekai Ittara Honki Dasu Ep. 14 · Showsite")
        other.playbackPosition = 300
        other.lastPlayedAt = Date(timeIntervalSince1970: 1_000)
        func listed() -> [UUID] { ShowPlaylist.continueWatching(store.episodes(of: show) + [other], shows: store.shows).map(\.id) }
        let (second, third) = (episodes[1].id, episodes[2].id)

        episodes[0].lastPlayedAt = Date(timeIntervalSince1970: 2_000)
        episodes[0].setWatched(true)
        downloads.delete(episodes[0])
        XCTAssertEqual(show.deletedEpisodePlayedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(listed(), [second, other.id], "episode 2 follows the deleted episode 1, most recent first")

        episodes[1].lastPlayedAt = Date(timeIntervalSince1970: 3_000)
        episodes[1].playbackPosition = 120
        XCTAssertEqual(listed(), [second, other.id], "now in progress, listed once")

        episodes[1].setWatched(true)
        downloads.delete(episodes[1])
        XCTAssertEqual(listed(), [third, other.id])

        // An unwatched episode leaves no mark.
        downloads.delete(episodes[2])
        XCTAssertEqual(show.deletedEpisodePlayedAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(listed(), [other.id])
    }

    func testNewEpisodesJoinTheirShow() {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        let show = store.create(title: "My Smoking Show", with: [1, 2].map { video("Sample Show Ep. \($0) · Showsite") })
        let third = video("Sample Show Ep. 3 · Showsite")
        XCTAssertTrue(store.addToMatchingShow(third) === show, "matched by the episodes' series, though the show was renamed")
        XCTAssertEqual(third.showOrder, 2)
        XCTAssertEqual(show.followSourceURL, third.sourcePageURL, "the latest episode's page is followed")
        XCTAssertNil(store.addToMatchingShow(video("Mushoku Tensei III: Isekai Ittara Honki Dasu Ep. 14 · Showsite")))
        XCTAssertNil(store.addToMatchingShow(video("Basic Video Page")), "no episode number")
    }

    func testMoviesLeaveShowsAndAreNeverSuggested() {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        let movies = [1, 2].map { video("Sample Show Ep. \($0) · Showsite") }
        movies.forEach { store.setMovie($0, true) }
        XCTAssertTrue(store.suggestions.isEmpty, "two movies of a series aren't a show")
        XCTAssertNil(store.addToMatchingShow(movies[0]))

        let show = store.create(title: "Smoking", with: [video("Sample Show Ep. 3 · Showsite")])
        store.add([movies[0]], to: show)
        XCTAssertFalse(movies[0].isMovie, "an episode isn't a movie")
        store.setMovie(movies[0], true)
        XCTAssertNil(movies[0].showID, "a movie isn't an episode")
        XCTAssertEqual(store.episodes(of: show).count, 1)
    }

    /// Unnumbered downloads can't move the check back an episode; shows made before checks get a followed page.
    func testTheFollowedPageIsTheHighestNumberedEpisode() {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        func episode(_ title: String, _ page: String) -> DownloadItem {
            let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).m3u8")!,
                                    sourcePageURL: URL(string: page)!, kind: .hls, status: .completed)
            container.mainContext.insert(item)
            return item
        }
        let seventh = episode("Watch Attack on Titan · Animesite", "https://www.animesite.example/watch/abc/attack-on-titan?ep=7")
        let unnumbered = episode("Attack on Titan special", "https://www.animesite.example/info/abc/attack-on-titan")
        let third = episode("Watch Attack on Titan · Animesite", "https://www.animesite.example/watch/abc/attack-on-titan?ep=3")
        let show = store.create(title: "Attack on Titan", with: [third, unnumbered, seventh])
        XCTAssertEqual(show.followSourceURL, seventh.sourcePageURL, "episode 7, from its address")

        show.followSourceURL = nil
        store.fillMissingFollowedPages()
        XCTAssertEqual(show.followSourceURL, seventh.sourcePageURL)
        store.remove(seventh)
        XCTAssertEqual(show.followSourceURL, third.sourcePageURL, "removing the latest follows the one before")
    }
}
