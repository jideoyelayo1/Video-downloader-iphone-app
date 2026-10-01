import AVFoundation
import AVKit
import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private var fileName: String!
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(for: DownloadItem.self, Bookmark.self, DownloadFolder.self, BrowsingHistoryEntry.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        fileName = "playback-test-\(UUID().uuidString).mp4"
        let source = try XCTUnwrap(FixtureSet.resourceURL(named: "fixture_captions.mp4", in: Bundle(for: LocalMediaServer.self)))
        try FileManager.default.copyItem(at: source, to: DownloadStorage.libraryDirectory.appendingPathComponent(fileName))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: DownloadStorage.libraryDirectory.appendingPathComponent(fileName))
    }

    private func makeItem(in context: ModelContext) -> DownloadItem {
        let item = DownloadItem(title: "Captioned", remoteURL: URL(string: "https://cdn.example/captions.mp4")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video, status: .completed)
        item.localFileName = fileName
        context.insert(item)
        return item
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("\(description) — not met within \(timeout) s") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opening and closing a saved video repeatedly must not keep old players alive.
    func testClosedPlayersAreReleased() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = "PlaybackCoordinatorTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log, preferences: preferences)
        let item = makeItem(in: container.mainContext)

        var released: [() -> Bool] = []
        for _ in 0..<3 {
            coordinator.open(item, at: 0)
            try await waitUntil("player ready") { coordinator.controller.player != nil && !coordinator.isLoading }
            weak var player = coordinator.controller.player
            weak var playerItem = coordinator.controller.player?.currentItem
            released.append { player == nil && playerItem == nil }
            try await Task.sleep(for: .milliseconds(300))
            coordinator.close()
        }
        try await waitUntil("closed players and items released") { released.allSatisfy { $0() } }
        XCTAssertNil(coordinator.controller.player)
    }

    /// Re-hosting one player controller in every new presentation kept each earlier presentation's
    /// views alive (about 0.75 MB per video opened). Each video now gets its own controller.
    func testEachVideoGetsItsOwnControllerAndThePreviousOneIsReleased() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log,
                                              preferences: try XCTUnwrap(UserDefaults(suiteName: "PlaybackCoordinatorTests-controllers")))
        let item = makeItem(in: container.mainContext)

        weak var first: AVPlayerViewController?
        do {
            coordinator.open(item, at: 0)
            try await waitUntil("first video ready") { coordinator.controller.player != nil && !coordinator.isLoading }
            first = coordinator.controller
            XCTAssertTrue(first?.delegate === coordinator)
            coordinator.close()
        }
        coordinator.open(item, at: 0)
        try await waitUntil("second video ready") { coordinator.controller.player != nil && !coordinator.isLoading }
        XCTAssertFalse(coordinator.controller === first)
        XCTAssertTrue(coordinator.controller.delegate === coordinator)
        XCTAssertTrue(coordinator.controller.allowsPictureInPicturePlayback)
        try await waitUntil("previous controller released") { first == nil }
        coordinator.close()
    }
}
