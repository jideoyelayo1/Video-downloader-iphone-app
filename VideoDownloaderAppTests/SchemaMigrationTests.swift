import SwiftData
import XCTest
@testable import VideoDownloaderApp

/// A library saved by an earlier build must still open after the models change. The fixture was
/// written by the models at b9fabea (before movies): that commit's Models/DownloadItem.swift built
/// for macOS with a short main.swift that saves one show, episode and label. Add one like it from
/// the last release before changing the models again.
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
