import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class LibraryBackupTests: XCTestCase {
    func testBackupRestoresRecordsAndMarksMissingFiles() throws {
        let sourceContainer = try LibrarySchema.container(inMemory: true)
        let source = sourceContainer.mainContext
        let fileName = "backup-\(UUID().uuidString).mp4"
        let file = DownloadStorage.libraryDirectory.appendingPathComponent(fileName)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let label = VideoLabel(name: "***REMOVED***", sites: ["***REMOVED***.to"], isSiteLabel: true)
        let show = Show(title: "***REMOVED***")
        show.introStart = 10
        show.introEnd = 100
        source.insert(label)
        source.insert(show)
        let present = DownloadItem(title: "Ep. 1", remoteURL: URL(string: "https://cdn.example/1.mp4")!,
                                   sourcePageURL: URL(string: "https://***REMOVED***.to/anime/x/p-1-dub")!, kind: .video, status: .completed)
        present.localFileName = fileName
        present.setWatched(true)
        present.labelIDs = [label.id]
        present.showID = show.id
        present.showOrder = 0
        let missing = DownloadItem(title: "Ep. 2", remoteURL: URL(string: "https://cdn.example/2.mp4")!,
                                   sourcePageURL: URL(string: "https://***REMOVED***.to/anime/x/p-2-dub")!, kind: .video, status: .completed)
        missing.localFileName = "gone-\(UUID().uuidString).mp4"
        missing.playbackPosition = 321
        source.insert(present)
        source.insert(missing)
        try source.save()

        let data = try LibraryBackup.make(from: source).encoded()
        let targetContainer = try LibrarySchema.container(inMemory: true)
        let target = targetContainer.mainContext
        let summary = try LibraryBackup.decode(data).restore(into: target)
        XCTAssertEqual(summary, LibraryBackup.Summary(added: 2, updated: 0, missingFiles: 1))
        let restored = try target.fetch(FetchDescriptor<DownloadItem>()).sorted { $0.title < $1.title }
        XCTAssertEqual(restored.map(\.title), ["Ep. 1", "Ep. 2"])
        XCTAssertTrue(restored[0].isWatched)
        XCTAssertEqual(restored[0].status, .completed)
        XCTAssertEqual(restored[0].labelIDs, [label.id])
        XCTAssertEqual(restored[1].status, .failed, "its file isn't here, so it waits to be downloaded again")
        XCTAssertEqual(restored[1].playbackPosition, 321)
        let restoredShow = try XCTUnwrap(target.fetch(FetchDescriptor<Show>()).first)
        XCTAssertEqual(restoredShow.introEnd, 100)
        XCTAssertEqual(try target.fetch(FetchDescriptor<VideoLabel>()).first?.name, "***REMOVED***")

        let again = try LibraryBackup.decode(data).restore(into: target)
        XCTAssertEqual(again.added, 0, "restoring twice merges")
        XCTAssertEqual(again.updated, 2)
        XCTAssertThrowsError(try LibraryBackup.decode(Data("{}".utf8)))
    }
}
