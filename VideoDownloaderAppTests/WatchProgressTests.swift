import XCTest
@testable import VideoDownloaderApp

final class WatchProgressTests: XCTestCase {
    func testTheLastTenPercentCountsAsFinished() {
        XCTAssertFalse(WatchProgress.isFinished(position: 1_200, duration: 1_440))
        XCTAssertTrue(WatchProgress.isFinished(position: 1_300, duration: 1_440), "a 24-minute episode closed during the credits")
        XCTAssertTrue(WatchProgress.isFinished(position: 1_440, duration: 1_440))
        XCTAssertFalse(WatchProgress.isFinished(position: 100, duration: nil), "unknown length")
        XCTAssertFalse(WatchProgress.isFinished(position: 100, duration: .nan))
        XCTAssertFalse(WatchProgress.isFinished(position: 0, duration: 0))
    }

    func testMarkingWatchedClearsTheResumePoint() {
        let item = DownloadItem(title: "Episode", remoteURL: URL(string: "https://cdn.example/a.mp4")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video)
        item.playbackPosition = 600
        item.setWatched(true)
        XCTAssertTrue(item.isWatched)
        XCTAssertEqual(item.playbackPosition, 0)
        item.setWatched(false)
        XCTAssertFalse(item.isWatched)
    }
}
