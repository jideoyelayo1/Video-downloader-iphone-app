import SwiftData
import UIKit
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class SeasonDownloaderTests: XCTestCase {
    func testNextEpisodeAddressesOnTheBookmarkedSites() {
        func next(_ string: String) -> String? { EpisodeURL.next(after: URL(string: string)!)?.absoluteString }
        XCTAssertEqual(next("https://***REMOVED***.to/anime/vpoY93SPHAQZP9soq/p-1-dub"), "https://***REMOVED***.to/anime/vpoY93SPHAQZP9soq/p-2-dub")
        XCTAssertEqual(next("https://***REMOVED***.to/anime/3BK5BYwFE5YNPriHj/p-9-dub"), "https://***REMOVED***.to/anime/3BK5BYwFE5YNPriHj/p-10-dub",
                       "letters and digits in the series id are left alone")
        XCTAssertEqual(next("https://www.***REMOVED***.to/watch/154587/frieren?ep=1"), "https://www.***REMOVED***.to/watch/154587/frieren?ep=2")
        XCTAssertEqual(next("https://my***REMOVED***.lol/watch/tv/2190-free-south-park-hd/season-29/episode-2/"),
                       "https://my***REMOVED***.lol/watch/tv/2190-free-south-park-hd/season-29/episode-3/")
        XCTAssertEqual(next("https://***REMOVED***.ws/***REMOVED***/the-office/season/2/episode/9"), "https://***REMOVED***.ws/***REMOVED***/the-office/season/2/episode/10")
        XCTAssertEqual(next("https://site.example/show-s01e09.html"), "https://site.example/show-s01e10.html")
        XCTAssertEqual(next("https://site.example/watch/one-piece/ep-1099"), "https://site.example/watch/one-piece/ep-1100")
        XCTAssertNil(next("https://***REMOVED***.ru/play/8a3c/5f2d1e0b7a"), "no episode number in the address")
        XCTAssertEqual(EpisodeURL.title("", numberedFrom: URL(string: "https://***REMOVED***.to/anime/x/p-9-dub")!), "", "an empty title stays empty")
        XCTAssertEqual(EpisodeURL.number(in: URL(string: "https://www.***REMOVED***.to/watch/1/x?ep=7")!), 7)
        XCTAssertEqual(next("https://***REMOVED***.su/watch/tv/213375/1/2"), "https://***REMOVED***.su/watch/tv/213375/1/3", "the last number is the episode")
        XCTAssertEqual(EpisodeURL.number(in: URL(string: "https://***REMOVED***.su/watch/tv/213375/1/9")!), 9)
        XCTAssertNil(next("https://***REMOVED***.su/watch/movie/213375"))
        XCTAssertTrue(SeasonDownloader.isVerificationPage(title: "Just a moment..."))

        let ***REMOVED*** = URL(string: "https://www.***REMOVED***.to/watch/W89s7g854PobER8iJIsw61vU_EkyYyOg/attack-on-titan?ep=2")!
        XCTAssertEqual(EpisodeURL.title("Watch Attack on Titan · ***REMOVED***", numberedFrom: ***REMOVED***), "Watch Attack on Titan Ep. 2 · ***REMOVED***",
                       "***REMOVED***'s titles don't say which episode")
        XCTAssertEqual(ShowSuggestion.parse(DownloadItem.displayTitle("Watch Attack on Titan Ep. 2 · ***REMOVED***", host: "www.***REMOVED***.to")),
                       .init(series: "Attack on Titan", season: nil, episode: 2))
        let ***REMOVED*** = URL(string: "https://***REMOVED***.to/anime/x/p-9-dub")!
        XCTAssertEqual(EpisodeURL.title("***REMOVED*** Ep. 9 · ***REMOVED***", numberedFrom: ***REMOVED***),
                       "***REMOVED*** Ep. 9 · ***REMOVED***", "titles that have a number are left alone")
    }

    func testEpisodesAlreadyInTheLibraryAreSkipped() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let container = try LibrarySchema.container(inMemory: true)
        let manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        manager.requestContextProvider = { _, _ in nil }
        let shows = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "SeasonDownloaderTests-\(UUID().uuidString)")!)
        let saved = DownloadItem(title: "Fixture Series Ep. 2", remoteURL: server.url("/series/video-2.mp4"),
                                 sourcePageURL: server.url("/series/ep-2.html"), kind: .video, status: .completed)
        container.mainContext.insert(saved)
        let downloader = SeasonDownloader(downloads: manager, shows: shows)
        downloader.pageTimeout = 15
        downloader.start(after: server.url("/series/ep-1.html"), count: 2)
        let deadline = Date().addingTimeInterval(60)
        while downloader.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        let titles = try container.mainContext.fetch(FetchDescriptor<DownloadItem>()).map(\.title).sorted()
        XCTAssertEqual(titles, ["Fixture Series Ep. 2", "Fixture Series Ep. 3"], "episode 2 isn't downloaded again")
        XCTAssertEqual(downloader.status, "Queued 1 episode.")
        for item in try container.mainContext.fetch(FetchDescriptor<DownloadItem>()) where item.id != saved.id {
            while item.isActive, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            manager.delete(item)
        }
    }

    /// From episode 1, "the next 3 episodes" finds 2 and 3, then stops because 4 isn't out.
    func testNextEpisodesAreFoundAndDownloaded() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let container = try LibrarySchema.container(inMemory: true)
        let manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        manager.requestContextProvider = { _, _ in nil }
        let shows = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "SeasonDownloaderTests-\(UUID().uuidString)")!)
        manager.showStore = shows
        let downloader = SeasonDownloader(downloads: manager, shows: shows)
        downloader.pageTimeout = 15

        downloader.start(after: server.url("/series/ep-1.html"), count: 3)
        let deadline = Date().addingTimeInterval(60)
        while downloader.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertFalse(downloader.isRunning)
        XCTAssertEqual(downloader.status, "Queued 2 episodes; no video found for the next one.")
        let items = try container.mainContext.fetch(FetchDescriptor<DownloadItem>()).sorted { $0.title < $1.title }
        XCTAssertEqual(items.map(\.title), ["Fixture Series Ep. 2", "Fixture Series Ep. 3"])
        XCTAssertEqual(items.map(\.sourcePageURL.lastPathComponent), ["ep-2.html", "ep-3.html"])
        while items.contains(where: \.isActive), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(items.allSatisfy { $0.status == .completed }, items.map { $0.errorMessage ?? "" }.joined(separator: "; "))
        for item in items { manager.delete(item) }
    }
}
