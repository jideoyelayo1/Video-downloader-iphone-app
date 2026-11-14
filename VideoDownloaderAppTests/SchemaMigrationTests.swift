import SwiftData
import XCTest
@testable import VideoDownloaderApp

/// Fixture saved by the models at b9fabea (before movies); add one from the last release before model changes.
@MainActor
final class SchemaMigrationTests: XCTestCase {
    func testALibrarySavedBeforeMoviesOpensWithItsVideos() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "library-b9fabea", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture, to: store)

        let container = try ModelContainer(for: Schema(LibrarySchema.models), configurations: ModelConfiguration(url: store))
        let context = ModelContext(container)
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<DownloadItem>()).first)
        let show = try XCTUnwrap(context.fetch(FetchDescriptor<Show>()).first)
        XCTAssertEqual(item.title, "Fixture Show Ep. 1")
        XCTAssertEqual(item.playbackPosition, 42)
        XCTAssertEqual(item.showID, show.id)
        XCTAssertFalse(item.isMovie, "a field added since reads as its default")
        XCTAssertEqual(try context.fetch(FetchDescriptor<VideoLabel>()).first?.name, "Fixture Label")
    }
}
