import Combine
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class DownloadProgressStoreTests: XCTestCase {
    func testThrottlePublishesFirstFinishedRestartedAndSpacedValues() {
        XCTAssertTrue(ProgressThrottle.shouldPublish(previous: nil, current: 0, secondsSincePublish: 0))
        XCTAssertFalse(ProgressThrottle.shouldPublish(previous: 0.4, current: 0.4, secondsSincePublish: 10))
        XCTAssertFalse(ProgressThrottle.shouldPublish(previous: 0.4, current: 0.41, secondsSincePublish: 0.05))
        XCTAssertTrue(ProgressThrottle.shouldPublish(previous: 0.4, current: 0.41, secondsSincePublish: 0.3))
        XCTAssertTrue(ProgressThrottle.shouldPublish(previous: 0.99, current: 1, secondsSincePublish: 0))
        XCTAssertTrue(ProgressThrottle.shouldPublish(previous: 0.6, current: 0, secondsSincePublish: 0))
    }

    func testRapidTicksPublishRarelyButReadsStayCurrent() {
        let store = DownloadProgressStore()
        let id = UUID()
        var publishes = 0
        let subscription = store.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }
        let start = Date()
        // 1,000 ticks within 0.1 s, as a fast direct download delivers them.
        for tick in 1...1_000 {
            store.set(id, fraction: Double(tick) / 2_000, now: start.addingTimeInterval(Double(tick) / 10_000))
        }
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(store.fraction(of: id), 0.5)
        XCTAssertEqual(store.fractions[id], 0.0005)

        store.set(id, fraction: 0.6, now: start.addingTimeInterval(1))
        XCTAssertEqual(store.fractions[id], 0.6)
        store.set(id, fraction: 1, now: start.addingTimeInterval(1.01))
        XCTAssertEqual(store.fractions[id], 1)
    }

    func testRemoveClearsValuesAndDoesNotNotifyWhenAlreadyEmpty() {
        let store = DownloadProgressStore()
        let id = UUID()
        store.set(id, fraction: 0.3)
        store.setEstimate(id, 42)
        store.remove(id)
        XCTAssertNil(store.fraction(of: id))
        XCTAssertNil(store.fractions[id])
        XCTAssertNil(store.estimatedSeconds[id])

        var publishes = 0
        let subscription = store.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }
        store.remove(id)
        store.setEstimate(id, nil)
        XCTAssertEqual(publishes, 0)
    }
}
