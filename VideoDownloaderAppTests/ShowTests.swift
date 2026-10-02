import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class ShowTests: XCTestCase {
    /// The titles of a real library (2026-10-02), as their sites named them.
    private let libraryTitles = [
        "Mushoku Tensei III: Isekai Ittara Honki Dasu Ep. 14 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 1 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 2 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 3 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 4 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 5 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 12 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 13 · ***REMOVED***",
        "Re:Zero kara Hajimeru Isekai Seikatsu Season 2 Ep. 9 · ***REMOVED***",
        "***REMOVED*** Ep. 1 · ***REMOVED***",
        "***REMOVED*** Ep. 10 · ***REMOVED***",
        "***REMOVED*** Ep. 2 · ***REMOVED***",
        "***REMOVED*** Ep. 3 · ***REMOVED***",
        "Watch South Park (1997) S29E2 - Watch Series - My***REMOVED***",
    ]
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try LibrarySchema.container(inMemory: true)
    }

    private func video(_ title: String) -> DownloadItem {
        let page = title.hasSuffix("My***REMOVED***") ? "https://my***REMOVED***.lol/watch/tv/2190" : "https://***REMOVED***.to/anime/x/p-1-dub"
        let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                sourcePageURL: URL(string: page)!, kind: .video, status: .completed)
        container.mainContext.insert(item)
        return item
    }

    func testSeriesAndEpisodeNumbersFromTitles() {
        func parse(_ title: String) -> ShowSuggestion.Parsed { ShowSuggestion.parse(title) }
        XCTAssertEqual(parse("***REMOVED*** Ep. 10"), .init(series: "***REMOVED***", season: nil, episode: 10))
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
        XCTAssertEqual(suggestions.map(\.series), ["Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2", "***REMOVED***",
                                                   "Re:Zero kara Hajimeru Isekai Seikatsu Season 2"],
                       "single episodes (Mushoku Tensei, South Park) aren't suggested")
        XCTAssertEqual(suggestions[1].items.map(\.displayTitle), [1, 2, 3, 10].map { "***REMOVED*** Ep. \($0)" })
        XCTAssertEqual(suggestions[2].items.map(\.displayTitle).map { ShowSuggestion.parse($0).episode }, [9, 12, 13])

        let dismissed = ShowSuggestion.suggestions(items: items, shows: [], dismissed: [suggestions[0].key])
        XCTAssertEqual(dismissed.count, 2, "Not Now hides a suggestion")
    }

    func testShowsKeepTheViewersOrderAndSuggestNewEpisodes() throws {
        let store = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "ShowTests-\(UUID().uuidString)")!)
        let episodes = [3, 1, 2].map { video("***REMOVED*** Ep. \($0) · ***REMOVED***") }
        let show = store.create(title: "***REMOVED***", with: ShowSuggestion.inEpisodeOrder(episodes))
        func order() -> [Int?] { store.episodes(of: show).map { ShowSuggestion.parse($0.displayTitle).episode } }
        XCTAssertEqual(order(), [1, 2, 3])

        store.move(in: show, from: [2], to: 0)
        XCTAssertEqual(order(), [3, 1, 2], "dragged into the viewer's own order")
        store.orderByEpisodeNumber(show)
        XCTAssertEqual(order(), [1, 2, 3])

        // A newer download of the same series is offered to the show, then appended.
        let fourth = video("***REMOVED*** Ep. 4 · ***REMOVED***")
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
}
