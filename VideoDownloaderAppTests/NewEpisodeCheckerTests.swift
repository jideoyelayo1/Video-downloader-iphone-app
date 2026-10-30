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
        }, download: { result in
            guard case .found(let candidate, let probe, _, let title, _) = result else { return nil }
            var named = candidate
            named.title = title
            return manager.start(named, expectedBytes: probe.expectedBytes)
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

    func testShowsCheckedLongestAgoGoFirstAndCatchUpOnSeveralEpisodes() async throws {
        let container = try LibrarySchema.container(inMemory: true)
        let context = container.mainContext
        let suite = "NewEpisodeCheckerTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = DownloadManager(context: context, directConfiguration: .ephemeral, restore: false)
        let shows = ShowStore(context: context, preferences: preferences)
        let now = Date()
        for (name, hoursAgo) in [("recent", 7.0), ("stale", 48.0)] {
            let first = DownloadItem(title: "\(name) Ep. 1", remoteURL: URL(string: "https://cdn.example/\(name)/1.mp4")!,
                                     sourcePageURL: URL(string: "https://site.example/\(name)/ep-1.html")!, kind: .video, status: .completed)
            context.insert(first)
            let show = shows.create(title: name, with: [first])
            show.autoDownloadNewEpisodes = true
            show.lastCheckedAt = now.addingTimeInterval(-hoursAgo * 3600)
        }
        var looked: [String] = []
        let out: Set<String> = ["/stale/ep-2.html", "/stale/ep-3.html"]
        let checker = NewEpisodeChecker(shows: shows, downloads: manager, preferences: preferences, find: { url in
            looked.append(url.path)
            guard out.contains(url.path) else { return .noVideo }
            return .found(MediaCandidate(url: url.appendingPathExtension("mp4"), sourcePageURL: url, title: "x", kind: .video),
                          ProbeResult(kind: .video, expectedBytes: 1), [], title: url.path)
        }, download: { result in
            guard case .found(let candidate, _, _, let title, _) = result else { return nil }
            let item = DownloadItem(title: title, remoteURL: candidate.url, sourcePageURL: candidate.sourcePageURL, kind: .video, status: .completed)
            context.insert(item)
            return item
        }, notify: { _, _ in })

        let found = await checker.checkFollowedShows(now: now)
        XCTAssertEqual(found, 2)
        XCTAssertEqual(looked, ["/stale/ep-2.html", "/stale/ep-3.html", "/stale/ep-4.html", "/recent/ep-2.html"])
    }

    func testTheNotificationOnlySaysDownloadingWhenItStarted() {
        XCTAssertEqual(NewEpisodeChecker.notificationBody(autoDownload: true, started: true), "It's downloading now.")
        XCTAssertFalse(NewEpisodeChecker.notificationBody(autoDownload: true, started: false).contains("downloading now"),
                       "a download refused for lack of storage isn't downloading")
        XCTAssertTrue(NewEpisodeChecker.notificationBody(autoDownload: false, started: false).contains("Browse"))
    }

    func testAnInterruptedCheckIsNotCountedAndSavedEpisodesAreFollowedOn() async throws {
        let container = try LibrarySchema.container(inMemory: true)
        let suite = "NewEpisodeCheckerTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        let shows = ShowStore(context: container.mainContext, preferences: preferences)
        func episode(_ number: Int) -> DownloadItem {
            let item = DownloadItem(title: "Series Ep. \(number)", remoteURL: URL(string: "https://cdn.example/\(number).mp4")!,
                                    sourcePageURL: URL(string: "https://site.example/series/ep-\(number)")!, kind: .video, status: .completed)
            container.mainContext.insert(item)
            return item
        }
        let show = shows.create(title: "Series", with: [episode(1)])
        show.notifyNewEpisodes = true
        let second = episode(2)
        var looked: [String] = []
        var result = SeasonDownloader.PageResult.noVideo
        let checker = NewEpisodeChecker(shows: shows, downloads: manager, preferences: preferences, find: { url in
            looked.append(url.lastPathComponent)
            return result
        }, download: { _ in nil }, notify: { _, _ in XCTFail("nothing new to announce") })

        _ = await checker.checkFollowedShows()
        XCTAssertEqual(looked, [], "episode 2 is already saved, so it isn't looked for")
        XCTAssertEqual(second.showID, show.id, "it joins the show, which follows on from it")
        XCTAssertEqual(show.followSourceURL?.lastPathComponent, "ep-2")
        XCTAssertNil(show.lastCheckedAt, "nothing was actually checked")

        let interrupted = Task { await checker.checkFollowedShows(force: true) }
        interrupted.cancel()
        _ = await interrupted.value
        XCTAssertNil(show.lastCheckedAt, "a check iOS cut short isn't counted")
        _ = await checker.checkFollowedShows(force: true)
        XCTAssertEqual(looked.last, "ep-3")
        XCTAssertNotNil(show.lastCheckedAt)
        XCTAssertNil(show.lastCheckNeededVerification)

        // A site's Cloudflare page isn't "not out yet": the show says the site wants verifying.
        result = .verification
        _ = await checker.checkFollowedShows(force: true)
        XCTAssertEqual(show.lastCheckNeededVerification, true)
        result = .noVideo
        _ = await checker.checkFollowedShows(force: true)
        XCTAssertNil(show.lastCheckNeededVerification, "cleared once the site lets the check through")
    }
}
