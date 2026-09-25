import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class PersistenceTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: DownloadItem.self, Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testDownloadItemRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let item = DownloadItem(title: "Episode 1", remoteURL: URL(string: "https://cdn.example/a.m3u8")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!,
                                refererURL: URL(string: "https://player.example/")!, kind: .hls, preferredBitrate: 800_000)
        context.insert(item)
        item.status = .completed
        item.localFileName = "@managed/Library/com.apple.UserManagedAssets.X/Episode_1.movpkg"
        try context.save()

        let fetched = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<DownloadItem>()).first)
        XCTAssertEqual(fetched.title, "Episode 1")
        XCTAssertEqual(fetched.kind, .hls)
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertEqual(fetched.preferredBitrate, 800_000)
        XCTAssertEqual(fetched.refererURL?.absoluteString, "https://player.example/")
        XCTAssertEqual(fetched.localURL, DownloadStorage.containerRoot.appendingPathComponent("Library/com.apple.UserManagedAssets.X/Episode_1.movpkg"))
    }

    func testManagedPathIsRelativeToContainer() {
        let inside = DownloadStorage.containerRoot.appendingPathComponent("Library/pkg.movpkg")
        XCTAssertEqual(DownloadStorage.managedPath(for: inside), "@managed/Library/pkg.movpkg")
        XCTAssertEqual(DownloadStorage.storedURL("@managed/Library/pkg.movpkg"), inside)
        XCTAssertEqual(DownloadStorage.storedURL("video.mp4"), DownloadStorage.libraryDirectory.appendingPathComponent("video.mp4"))
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
        XCTAssertNotNil(items[1].errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("imported").path))
        XCTAssertEqual(LegacyDownloadImport.run(into: context, from: url), 0, "import runs once")
    }
}
