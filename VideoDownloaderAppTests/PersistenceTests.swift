import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class PersistenceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try LibrarySchema.container(inMemory: true)
    }

    func testDownloadItemRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = DownloadItem(title: "Episode 1", remoteURL: URL(string: "https://cdn.example/a.m3u8")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!,
                                refererURL: URL(string: "https://player.example/")!, kind: .hls,
                                preferredBitrate: 800_000, requiresReferer: true)
        context.insert(item)
        item.status = .completed
        item.localFileName = "@managed/Library/com.apple.UserManagedAssets.X/Episode_1.movpkg"
        try context.save()

        let fetched = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<DownloadItem>()).first)
        XCTAssertEqual(fetched.title, "Episode 1")
        XCTAssertEqual(fetched.kind, .hls)
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertEqual(fetched.preferredBitrate, 800_000)
        XCTAssertTrue(fetched.requiresReferer)
        XCTAssertEqual(fetched.refererURL?.absoluteString, "https://player.example/")
        XCTAssertEqual(fetched.localURL, DownloadStorage.containerRoot.appendingPathComponent("Library/com.apple.UserManagedAssets.X/Episode_1.movpkg"))
    }

    func testWatchedLabelsAndShowsPersist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let label = VideoLabel(name: "Showsite", colorName: "purple", sites: ["showsite.example"], isSiteLabel: true)
        let show = Show(title: "Sample Show")
        let item = DownloadItem(title: "Sample Show Ep. 2 · Showsite", remoteURL: URL(string: "https://cdn.example/2.mp4")!,
                                sourcePageURL: URL(string: "https://showsite.example/anime/x/p-2-dub")!, kind: .video)
        let watched = Date(timeIntervalSince1970: 1_790_000_000)
        item.watchedAt = watched
        item.lastPlayedAt = watched
        item.duration = 1_420
        item.labelIDs = [label.id]
        item.showID = show.id
        item.showOrder = 1
        context.insert(label)
        context.insert(show)
        context.insert(item)
        try context.save()

        let fresh = ModelContext(container)
        let fetched = try XCTUnwrap(fresh.fetch(FetchDescriptor<DownloadItem>()).first)
        XCTAssertTrue(fetched.isWatched)
        XCTAssertEqual(fetched.watchedAt, watched)
        XCTAssertEqual(fetched.duration, 1_420)
        XCTAssertEqual(fetched.labelIDs, [label.id])
        XCTAssertEqual(fetched.showID, show.id)
        XCTAssertEqual(fetched.showOrder, 1)
        let fetchedLabel = try XCTUnwrap(fresh.fetch(FetchDescriptor<VideoLabel>()).first)
        XCTAssertEqual(fetchedLabel.sites, ["showsite.example"])
        XCTAssertEqual(fetchedLabel.isSiteLabel, true)
        XCTAssertTrue(try XCTUnwrap(fresh.fetch(FetchDescriptor<Show>()).first).autoplayNext, "autoplay is on for new shows")
    }

    func testManagedPathIsRelativeToContainer() {
        let inside = DownloadStorage.containerRoot.appendingPathComponent("Library/pkg.movpkg")
        XCTAssertEqual(DownloadStorage.managedPath(for: inside), "@managed/Library/pkg.movpkg")
        XCTAssertEqual(DownloadStorage.storedURL("@managed/Library/pkg.movpkg"), inside)
        XCTAssertEqual(DownloadStorage.storedURL("video.mp4"), DownloadStorage.libraryDirectory.appendingPathComponent("video.mp4"))
    }

    func testVideosAreLeftOutOfDeviceBackups() throws {
        let values = try DownloadStorage.libraryDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// iOS 27 reports HLS packages under /.nofollow/private/var/…, and every install moves the app's container.
    func testHLSPackagesAreFoundAfterAnInstallMovesTheContainer() throws {
        let package = "com.apple.UserManagedAssets.5BGDwz/Aniwave%20-%20Code%20Geass:%20Lelouch%20of%20the%20Rebellion%20R2.movpkg"
        let reported = "/.nofollow/private/var/mobile/Containers/Data/Application/E51660F9-E96F-4CDB-8E9B-D64DA8A449F2/Library/" + package
        XCTAssertEqual(DownloadStorage.managedPath(for: URL(fileURLWithPath: reported)), "@managed/" + package)
        XCTAssertEqual(DownloadStorage.storedURL(reported), DownloadStorage.containerRoot.appendingPathComponent(package),
                       "an absolute path saved by an earlier install")

        let file = DownloadStorage.containerRoot.appendingPathComponent("com.apple.UserManagedAssets.Test/Episode \(UUID().uuidString).movpkg")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let item = DownloadItem(title: "Episode", remoteURL: URL(string: "https://cdn.example/master.m3u8")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!, kind: .hls, status: .completed)
        item.localFileName = "/private/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000/Library/com.apple.UserManagedAssets.Test/"
            + file.lastPathComponent
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.localURL).path), "so it plays instead of 'file is missing'")

        XCTAssertEqual(DownloadStorage.storedURL("/tmp/video.mp4").path, "/tmp/video.mp4")
        let shared = "/var/mobile/Containers/Shared/AppGroup/E51660F9-E96F-4CDB-8E9B-D64DA8A449F2/Library/video.mp4"
        XCTAssertEqual(DownloadStorage.storedURL(shared).path, shared)
    }

    func testOldSegmentDownloadIsRecognisedAsAFragment() {
        let item = DownloadItem(title: "Episode", remoteURL: URL(string: "https://segments.example/vd/episode/seg-57-s1080p-v1-a1.m4s")!,
                                sourcePageURL: URL(string: "https://example.com/watch")!, kind: .video)
        XCTAssertTrue(item.isStreamFragment)
    }

    func testDownloadedTextShowsTheDateAndTime() {
        let added = Date(timeIntervalSince1970: 1_600_000_000)
        let item = DownloadItem(title: "Episode", remoteURL: URL(string: "https://cdn.example/a.mp4")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video, createdAt: added)
        let addedTime = DateFormatter.localizedString(from: added, dateStyle: .none, timeStyle: .short)
        XCTAssertTrue(item.downloadedText.hasPrefix("Added "), item.downloadedText)
        XCTAssertTrue(item.downloadedText.contains("2020") && item.downloadedText.contains(addedTime), item.downloadedText)
        XCTAssertNil(item.completedTimeText)

        let finished = Date()
        item.completedAt = finished
        let finishedTime = DateFormatter.localizedString(from: finished, dateStyle: .none, timeStyle: .short)
        XCTAssertEqual(item.downloadedText, "Downloaded today at \(finishedTime)")
        XCTAssertEqual(item.completedTimeText, "today at \(finishedTime)")
    }

    func testFolderAndPlaybackPositionPersist() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let folder = DownloadFolder(title: "Anime")
        let item = DownloadItem(title: "Episode", remoteURL: URL(string: "https://cdn.example/a.mp4")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video)
        context.insert(folder)
        context.insert(item)
        item.folderID = folder.id
        item.playbackPosition = 123.5
        try context.save()

        let reopened = ModelContext(container)
        let storedItem = try XCTUnwrap(reopened.fetch(FetchDescriptor<DownloadItem>()).first)
        let storedFolder = try XCTUnwrap(reopened.fetch(FetchDescriptor<DownloadFolder>()).first)
        XCTAssertEqual(storedItem.folderID, storedFolder.id)
        XCTAssertEqual(storedItem.playbackPosition, 123.5)
    }

    func testLegacyJSONImportMarksInterruptedItemsAndRenamesFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let json = """
        [{"id":"7B1B3A0E-8F52-4A55-9C61-0C3C5C2A1D11","title":"Old","remoteURL":"https://cdn.example/a.mp4",
          "sourcePageURL":"https://site.example/w","kind":"video","localFileName":"Old.mp4","status":"completed",
          "progress":1,"createdAt":700000000,"completedAt":700000100},
         {"id":"7B1B3A0E-8F52-4A55-9C61-0C3C5C2A1D12","title":"Half","remoteURL":"https://cdn.example/b.mp4",
          "sourcePageURL":"https://site.example/w","kind":"video","status":"downloading","progress":0.4,"createdAt":700000200}]
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)

        XCTAssertEqual(LegacyDownloadImport.run(into: context, from: url), 2)
        let items = try context.fetch(FetchDescriptor<DownloadItem>(sortBy: [SortDescriptor(\.createdAt)]))
        XCTAssertEqual(items.map(\.title), ["Old", "Half"])
        XCTAssertEqual(items[0].status, .completed)
        XCTAssertEqual(items[1].status, .failed)
        XCTAssertFalse(items[0].requiresReferer)
        XCTAssertNotNil(items[1].errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("imported").path))
        XCTAssertEqual(LegacyDownloadImport.run(into: context, from: url), 0, "import runs once")
    }
}
