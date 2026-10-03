import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class NewEpisodeCheckerTests: XCTestCase {
    func testAFollowedShowsNextEpisodeIsAnnouncedOnceAndCanDownloadItself() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let container = try LibrarySchema.container(inMemory: true)
        let suite = "NewEpisodeCheckerTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        manager.requestContextProvider = { _, _ in nil }
        let shows = ShowStore(context: container.mainContext, preferences: preferences)
        manager.showStore = shows

        let first = DownloadItem(title: "Fixture Series Ep. 1", remoteURL: server.url("/series/video-1.mp4"),
                                 sourcePageURL: server.url("/series/ep-1.html"), kind: .video, status: .completed)
        container.mainContext.insert(first)
        let show = shows.create(title: "Fixture Series", with: [first])
        XCTAssertEqual(show.followSourceURL, server.url("/series/ep-1.html"))

        var outPages: Set<String> = []
        var looked: [String] = []
        var notifications: [String] = []
        let checker = NewEpisodeChecker(shows: shows, downloads: manager, preferences: preferences, find: { url in
            looked.append(url.lastPathComponent)
            guard outPages.contains(url.lastPathComponent) else { return .noVideo }
            return .found(MediaCandidate(url: server.url("/series/video-2.mp4"), sourcePageURL: url, title: "x", kind: .video),
                          ProbeResult(kind: .video, expectedBytes: 1_000), [], title: "Fixture Series Ep. 2")
        }, notify: { title, _ in notifications.append(title) })

        var found = await checker.checkFollowedShows()
        XCTAssertEqual(found, 0)
        XCTAssertEqual(looked, [], "nobody follows the show yet")

        show.notifyNewEpisodes = true
        found = await checker.checkFollowedShows()
        XCTAssertEqual(found, 0)
        XCTAssertEqual(looked, ["ep-2.html"])
        found = await checker.checkFollowedShows()
        XCTAssertEqual(looked, ["ep-2.html"], "not checked again within the interval")

        outPages = ["ep-2.html"]
        show.autoDownloadNewEpisodes = true
        found = await checker.checkFollowedShows(force: true)
        XCTAssertEqual(found, 1)
        XCTAssertEqual(notifications, ["Episode 2 of Fixture Series is out"])
        let episodes = shows.episodes(of: show)
        XCTAssertEqual(episodes.map(\.title), ["Fixture Series Ep. 1", "Fixture Series Ep. 2"], "downloaded into the show")
        XCTAssertEqual(show.followSourceURL?.lastPathComponent, "ep-2.html", "now following episode 2")

        _ = await checker.checkFollowedShows(force: true)
        XCTAssertEqual(looked.last, "ep-3.html")
        XCTAssertEqual(notifications.count, 1, "each episode is announced once")
        for item in episodes where item.id != first.id { manager.delete(item) }
    }
}
