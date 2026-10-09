import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class StorageCleanupTests: XCTestCase {
    func testWatchedVideosAreDeletedAWeekLaterOnlyWhenAskedTo() throws {
        let container = try LibrarySchema.container(inMemory: true)
        let suite = "StorageCleanupTests-\(UUID().uuidString)"
        let manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        manager.preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { manager.preferences.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func video(_ title: String, watchedDaysAgo: Double?) -> DownloadItem {
            let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                    sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video, status: .completed)
            item.fileSize = 100_000_000
            item.watchedAt = watchedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
            container.mainContext.insert(item)
            return item
        }
        let old = video("Old", watchedDaysAgo: 8)
        let recent = video("Recent", watchedDaysAgo: 2)
        let unwatched = video("Unwatched", watchedDaysAgo: nil)
        XCTAssertEqual(StorageCleanup.watched([old, recent, unwatched], olderThan: 7, now: now).map(\.title), ["Old"])
        XCTAssertEqual(StorageCleanup.totalSize([old, recent]), 200_000_000)

        XCTAssertEqual(manager.deleteOldWatchedVideos(now: now), 0, "off unless turned on")
        manager.deletesWatchedAfterAWeek = true
        XCTAssertEqual(manager.deleteOldWatchedVideos(now: now), 1)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<DownloadItem>()).map(\.title).sorted(), ["Recent", "Unwatched"])
        _ = recent; _ = unwatched
    }

    func testDeletingAShowWithItsEpisodes() throws {
        let container = try LibrarySchema.container(inMemory: true)
        let suite = "StorageCleanupTests-\(UUID().uuidString)"
        let manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        manager.preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { manager.preferences.removePersistentDomain(forName: suite) }
        let shows = ShowStore(context: container.mainContext, preferences: manager.preferences)
        manager.showStore = shows
        XCTAssertEqual(manager.finishedEpisodes, .keep, "finished episodes stay unless chosen")
        manager.finishedEpisodes = .ask
        XCTAssertEqual(manager.finishedEpisodes, .ask)

        func video(_ title: String, status: DownloadStatus = .completed) throws -> DownloadItem {
            let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                    sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video, status: status)
            if status == .completed {
                item.localFileName = "storage-cleanup-\(UUID().uuidString).mp4"
                let file = try XCTUnwrap(item.localURL)
                try Data(count: 1_000).write(to: file)
                addTeardownBlock { try? FileManager.default.removeItem(at: file) }
            }
            container.mainContext.insert(item)
            return item
        }
        let episodes = [try video("Fixture Show Ep. 1"), try video("Fixture Show Ep. 2"), try video("Fixture Show Ep. 3", status: .queued)]
        let files = episodes.compactMap(\.localURL)
        let other = try video("Other")
        let show = shows.create(title: "Fixture Show", with: episodes)

        manager.deleteShowAndEpisodes(show)
        XCTAssertTrue(shows.shows.isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<DownloadItem>()).map(\.title), ["Other"],
                       "every episode goes, including one still to download; other videos stay")
        XCTAssertEqual(files.count, 2)
        XCTAssertFalse(files.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(other.localURL).path))
    }
}
