import UIKit
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class ThumbnailCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).jpegData(withCompressionQuality: 0.8) { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
    }

    private func makeCache(_ generator: @escaping ThumbnailCache.Generator) -> ThumbnailCache {
        let directory = directory!
        return ThumbnailCache(generator: generator, thumbnailURL: { directory.appendingPathComponent("\($0.uuidString).jpg") })
    }

    func testConcurrentRequestsShareOneExtractionAndReuseTheResult() async {
        var calls = 0
        let cache = makeCache { _, _ in
            calls += 1
            try? await Task.sleep(for: .milliseconds(50))
            return Self.jpeg
        }
        let id = UUID()
        let media = URL(fileURLWithPath: "/tmp/video.mp4")
        async let first = cache.image(for: id, fileName: "a.mp4", mediaURL: media, kind: .video)
        async let second = cache.image(for: id, fileName: "a.mp4", mediaURL: media, kind: .video)
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(cache.cachedImage(for: id, fileName: "a.mp4"))
        XCTAssertNil(cache.cachedImage(for: id, fileName: "other.mp4"), "a re-downloaded file must not reuse the old thumbnail")
        _ = await cache.image(for: id, fileName: "a.mp4", mediaURL: media, kind: .video)
        XCTAssertEqual(calls, 1)
    }

    func testFailureIsRememberedUntilEvicted() async {
        var calls = 0
        let cache = makeCache { _, _ in calls += 1; return nil }
        let id = UUID()
        let media = URL(fileURLWithPath: "/tmp/broken.m3u8")
        for _ in 0..<3 { _ = await cache.image(for: id, fileName: "b.movpkg", mediaURL: media, kind: .hls) }
        XCTAssertEqual(calls, 1)
        cache.evict(id)
        _ = await cache.image(for: id, fileName: "b.movpkg", mediaURL: media, kind: .hls)
        XCTAssertEqual(calls, 2)
    }

    func testExtractionsRunOneAtATime() async {
        var running = 0
        var peak = 0
        let cache = makeCache { _, _ in
            running += 1
            peak = max(peak, running)
            try? await Task.sleep(for: .milliseconds(20))
            running -= 1
            return Self.jpeg
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    _ = await cache.image(for: UUID(), fileName: "\(index).m3u8", mediaURL: URL(fileURLWithPath: "/tmp/\(index)"), kind: .hls)
                }
            }
        }
        XCTAssertEqual(peak, 1)
    }

    func testSavedThumbnailIsReadFromDiskWithoutExtracting() async throws {
        let id = UUID()
        try XCTUnwrap(Self.jpeg).write(to: directory.appendingPathComponent("\(id.uuidString).jpg"))
        var calls = 0
        let cache = makeCache { _, _ in calls += 1; return nil }
        let image = await cache.image(for: id, fileName: "c.mp4", mediaURL: URL(fileURLWithPath: "/tmp/c.mp4"), kind: .video)
        XCTAssertNotNil(image)
        XCTAssertEqual(calls, 0)
    }
}
