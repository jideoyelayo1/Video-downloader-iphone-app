import XCTest
@testable import VideoDownloaderApp

final class DownloadTimeEstimateTests: XCTestCase {
    func testUsesObservedProgressRateAndIgnoresUnreliableSamples() {
        XCTAssertEqual(DownloadTimeEstimate.seconds(elapsed: 10, from: 0.25, to: 0.5), 20)
        XCTAssertNil(DownloadTimeEstimate.seconds(elapsed: 1, from: 0.25, to: 0.5))
        XCTAssertNil(DownloadTimeEstimate.seconds(elapsed: 10, from: 0.5, to: 0.5))
        XCTAssertNil(DownloadTimeEstimate.seconds(elapsed: 10, from: 0.5, to: 1))
    }
}
