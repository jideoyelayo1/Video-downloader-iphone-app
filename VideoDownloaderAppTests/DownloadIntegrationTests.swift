import SwiftData
import XCTest
@testable import VideoDownloaderApp

/// Drives the real download delegate code against `LocalMediaServer` using a foreground session.
@MainActor
final class DownloadIntegrationTests: XCTestCase {
    private var server: LocalMediaServer!
    private var container: ModelContainer!
    private var manager: DownloadManager!
    private var requestContext: RequestContext?

    override func setUp() async throws {
        server = try LocalMediaServer()
        try server.start()
        container = try ModelContainer(for: DownloadItem.self, Bookmark.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        manager = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        requestContext = nil
        manager.requestContextProvider = { [weak self] _, _ in self?.requestContext }
    }

    override func tearDown() async throws {
        for item in (try? container.mainContext.fetch(FetchDescriptor<DownloadItem>())) ?? [] { manager.delete(item) }
        server.stop()
        server = nil
        manager = nil
        container = nil
    }

    private func candidate(_ path: String, kind: MediaKind? = nil, title: String = "Fixture video") -> MediaCandidate {
        MediaCandidate(url: server.url(path), sourcePageURL: server.url("/page/basic.html"), title: title, kind: kind)
    }

    private func start(_ path: String, kind: MediaKind? = nil) throws -> DownloadItem {
        try XCTUnwrap(manager.start(candidate(path, kind: kind)))
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for condition"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForFinish(_ item: DownloadItem) async throws {
        try await waitUntil { !item.isActive }
    }

    private func sessionCookie(domain: String = "127.0.0.1") -> HTTPCookie {
        HTTPCookie(properties: [.name: "session", .value: "ok", .domain: domain, .path: "/"])!
    }

    // MARK: Direct files

    func testDirectMP4DownloadsCompletely() async throws {
        let item = try start("/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
        let file = try XCTUnwrap(item.localURL)
        XCTAssertEqual(try Data(contentsOf: file), server.fixtures.mp4)
        XCTAssertEqual(file.pathExtension, "mp4")
        XCTAssertTrue(file.lastPathComponent.hasPrefix("Fixture video-"))
        XCTAssertNotNil(item.fileSize)
        XCTAssertEqual(manager.progress(of: item), 1)
    }

    func testExtensionlessURLUsesContentTypeForFileExtension() async throws {
        let item = try start("/noext/stream?id=1", kind: .unknown)
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
        XCTAssertEqual(item.localURL?.pathExtension, "mp4")
    }

    func testRedirectIsFollowed() async throws {
        let item = try start("/redirect/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
    }

    func testCookieDependentMediaUsesScopedBrowserCookies() async throws {
        let denied = try start("/cookie/video.mp4")
        try await waitForFinish(denied)
        XCTAssertEqual(denied.status, .failed)
        XCTAssertEqual(denied.errorMessage, DownloadError.expiredLink.message)

        requestContext = RequestContext(cookies: [sessionCookie(), sessionCookie(domain: "other.example")],
                                        userAgent: "FixtureAgent/1", referer: nil)
        manager.retry(denied)
        try await waitForFinish(denied)
        XCTAssertEqual(denied.status, .completed, denied.errorMessage ?? "")
        let request = try XCTUnwrap(server.requests(to: "/cookie/video.mp4").last)
        XCTAssertEqual(request.header("Cookie"), "session=ok")
        XCTAssertEqual(request.header("User-Agent"), "FixtureAgent/1")
    }

    func testCookiesAreNotSentAcrossHostsOnRedirect() async throws {
        requestContext = RequestContext(cookies: [sessionCookie()], userAgent: nil, referer: nil)
        let item = try start("/redirect-cross/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(server.requests(to: "/redirect-cross/video.mp4").last?.header("Cookie"), "session=ok")
        let echoed = try XCTUnwrap(server.requests(to: "/echo-cookie").last)
        XCTAssertNil(echoed.header("Cookie"), "127.0.0.1 cookies must not reach localhost")
        XCTAssertEqual(item.status, .failed, "text/plain is not a video")
    }

    func testRefererRequiredMedia() async throws {
        requestContext = RequestContext(cookies: [], userAgent: nil, referer: server.url("/page/basic.html"))
        let item = try start("/referer/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
    }

    func testExpiredAndMissingLinksFailWithClearMessages() async throws {
        let expired = try start("/expired/video.mp4")
        let missing = try start("/missing.mp4")
        try await waitForFinish(expired)
        try await waitForFinish(missing)
        XCTAssertEqual(expired.errorMessage, DownloadError.expiredLink.message)
        XCTAssertEqual(missing.errorMessage, DownloadError.notFound.message)
        XCTAssertNil(expired.localURL)
    }

    func testNewSourceForSameFailedEpisodeReusesDownloadRow() async throws {
        let first = try start("/expired/video.mp4")
        try await waitForFinish(first)
        let replacement = try start("/missing.mp4")
        XCTAssertEqual(replacement.id, first.id)
        try await waitForFinish(replacement)
        XCTAssertEqual(replacement.remoteURL, server.url("/missing.mp4"))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 1)
    }

    func testHTMLErrorPageIsRejected() async throws {
        let item = try start("/html/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .failed)
        XCTAssertEqual(item.errorMessage, DownloadError.notVideo.message)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: DownloadStorage.libraryDirectory.path)
        XCTAssertFalse(leftovers.contains { $0.contains(item.id.uuidString) })
    }

    func testInvalidMP4IsNotAddedToLibrary() async throws {
        let item = try start("/invalid/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .failed)
        XCTAssertNil(item.localURL)
        XCTAssertTrue(item.errorMessage?.contains("cannot play") == true)
    }

    func testStreamSegmentCannotBeQueuedAsVideo() throws {
        let fragment = candidate("/hls/seg-57-s1080p-v1-a1.m4s", kind: .video)
        XCTAssertNil(manager.start(fragment))
        XCTAssertEqual(manager.startError, DownloadError.streamSegment.message)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 0)
    }

    func testNetworkInterruptionFailsAndCanBeRetried() async throws {
        let item = try start("/drop/video.mp4")
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .failed)
        XCTAssertNotNil(item.errorMessage)
        manager.retry(item)
        XCTAssertEqual(item.status, .downloading)
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .failed, "the fixture always drops")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 1, "retry reuses the item")
    }

    func testCancelThenRetryCompletesTheSameItem() async throws {
        let item = try start("/slow/video.mp4")
        try await waitUntil { manager.progress(of: item) > 0.1 }
        manager.cancel(item)
        XCTAssertEqual(item.status, .cancelled)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(item.status, .cancelled, "the late cancellation callback must not mark it failed")

        manager.retry(item)
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.localURL)), server.fixtures.mp4)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 1)
    }

    func testCancelledContextLookupCannotStartAfterRetry() async throws {
        // Hold both browser-context lookups. Resuming the first after cancel +
        // retry must not create a stale task for the same item.
        var calls = 0
        var pending: [CheckedContinuation<RequestContext?, Never>] = []
        manager.requestContextProvider = { _, _ in
            calls += 1
            return await withCheckedContinuation { continuation in
                pending.append(continuation)
            }
        }

        let item = try start("/video.mp4")
        try await waitUntil { calls == 1 }
        manager.cancel(item)
        manager.retry(item)
        try await waitUntil { calls == 2 }

        pending[0].resume(returning: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(server.requests(to: "/video.mp4").isEmpty, "the cancelled lookup started a stale download")

        pending[1].resume(returning: nil)
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
        XCTAssertEqual(server.requests(to: "/video.mp4").count, 1)
    }

    func testImmediateRetryIgnoresLateCancelledTaskCompletion() async throws {
        var calls = 0
        var retryContext: CheckedContinuation<RequestContext?, Never>?
        manager.requestContextProvider = { _, _ in
            calls += 1
            guard calls > 1 else { return nil }
            return await withCheckedContinuation { continuation in
                retryContext = continuation
            }
        }

        let item = try start("/slow/video.mp4")
        try await waitUntil { manager.progress(of: item) > 0.1 }
        manager.cancel(item)
        manager.retry(item)
        try await waitUntil { calls == 2 }

        // The cancelled task's completion can arrive while the retry is still
        // waiting for browser context. It must not cancel the new attempt.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(item.status, .downloading)

        retryContext?.resume(returning: nil)
        try await waitForFinish(item)
        XCTAssertEqual(item.status, .completed, item.errorMessage ?? "")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 1)
    }

    func testDuplicateActiveDownloadIsNotQueuedTwice() async throws {
        let first = try start("/slow/video.mp4")
        let second = try start("/slow/video.mp4")
        XCTAssertEqual(first.id, second.id)
        manager.cancel(first)
    }

    func testDeleteRemovesFileAndRecord() async throws {
        let item = try start("/video.mp4")
        try await waitForFinish(item)
        let file = try XCTUnwrap(item.localURL)
        manager.delete(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 0)
    }

    func testRenameKeepsFile() async throws {
        let item = try start("/video.mp4")
        try await waitForFinish(item)
        manager.rename(item, to: "  My episode  ")
        XCTAssertEqual(item.title, "My episode")
        manager.rename(item, to: "   ")
        XCTAssertEqual(item.title, "My episode")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.localURL).path))
    }

    func testInsufficientStorageRefusesToStart() throws {
        XCTAssertNil(manager.start(candidate("/video.mp4"), expectedBytes: Int64.max / 2))
        XCTAssertNotNil(manager.startError)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadItem>()), 0)
    }

    func testRelaunchMarksOrphanedDownloadsInterrupted() async throws {
        let orphan = DownloadItem(title: "Orphan", remoteURL: server.url("/video.mp4"), sourcePageURL: server.url("/page/basic.html"), kind: .video, status: .downloading)
        container.mainContext.insert(orphan)
        await manager.restoreTasks()
        XCTAssertEqual(orphan.status, .failed)
        XCTAssertEqual(orphan.errorMessage, "Download was interrupted. Tap Retry.")
        manager.retry(orphan)
        try await waitForFinish(orphan)
        XCTAssertEqual(orphan.status, .completed, orphan.errorMessage ?? "")
    }

    func testSiteSubtitlesAreSavedWithTheDownloadAndDeletedWithIt() async throws {
        let page = server.url("/page/tracks.html")
        let tracks = [SubtitleTrack(url: server.url("/subs/en.vtt"), label: "English", language: "en", isDefault: true, referer: page),
                      SubtitleTrack(url: server.url("/subs/es.vtt"), label: "Español", language: "es", isDefault: false, referer: page)]
        let item = try XCTUnwrap(manager.start(candidate("/video.mp4"), subtitles: tracks))
        let id = item.id
        try await waitUntil { SubtitleStore.saved(for: id).count == 2 }
        XCTAssertEqual(SubtitleStore.saved(for: id).first?.isDefault, true)
        try await waitUntil { item.status == .completed }
        manager.delete(item)
        XCTAssertTrue(SubtitleStore.saved(for: id).isEmpty)
    }
}

/// Probes run before a candidate is offered.
final class CandidateValidatorTests: XCTestCase {
    private var server: LocalMediaServer!
    private let validator = CandidateValidator()

    override func setUpWithError() throws {
        server = try LocalMediaServer()
        try server.start()
    }

    override func tearDown() { server.stop() }

    private func validate(_ path: String, kind: MediaKind? = nil, context: RequestContext? = nil) async -> CandidateStatus {
        await validator.validate(MediaCandidate(url: server.url(path), sourcePageURL: server.url("/page/basic.html"), kind: kind), context: context)
    }

    func testDirectFileIsReadyWithSize() async {
        let status = await validate("/video.mp4")
        XCTAssertEqual(status, .ready(ProbeResult(kind: .video, expectedBytes: Int64(server.fixtures.mp4.count))))
        XCTAssertEqual(server.requests(to: "/video.mp4").last?.header("Range"), "bytes=0-4095")
    }

    func testStreamSegmentIsUnavailableBeforeNetworkProbe() async {
        let status = await validate("/hls/seg-57-s1080p-v1-a1.m4s", kind: .video)
        XCTAssertEqual(status, .unavailable(.streamSegment))
        XCTAssertTrue(server.requests(to: "/hls/seg-57-s1080p-v1-a1.m4s").isEmpty)
    }

    func testExtensionlessFileIsClassifiedAsVideo() async {
        guard case .ready(let probe) = await validate("/noext/stream?id=1", kind: .unknown) else { return XCTFail() }
        XCTAssertEqual(probe.kind, .video)
    }

    func testPlaylistDisguisedAsFileIsReclassifiedAsHLS() async {
        guard case .ready(let probe) = await validate("/hls/media.m3u8", kind: .video) else { return XCTFail() }
        XCTAssertEqual(probe.kind, .hls)
        XCTAssertEqual(probe.duration ?? 0, 5, accuracy: 0.01)
    }

    func testMasterPlaylistReportsVariantsAndEstimatedSize() async {
        guard case .ready(let probe) = await validate("/hls/master.m3u8") else { return XCTFail() }
        XCTAssertEqual(probe.kind, .hls)
        XCTAssertEqual(probe.variants.map(\.qualityLabel), ["360p", "180p"])
        XCTAssertEqual(probe.expectedBytes, Int64(900_000 / 8 * 5))
        XCTAssertFalse(server.requests(to: "/hls/fixture_seg0.ts").isEmpty, "first segment is probed")
    }

    func testLiveAndProtectedStreamsAreUnavailable() async {
        let live = await validate("/hls/live.m3u8")
        let drm = await validate("/hls/drm.m3u8")
        XCTAssertEqual(live, .unavailable(.liveStream))
        XCTAssertEqual(drm, .unavailable(.protectedStream))
    }

    func testHTMLOrNestedPlaylistFirstSegmentIsRejected() async {
        let html = await validate("/hls/html-segment.m3u8")
        let nestedPlaylist = await validate("/hls/nested-playlist-segment.m3u8")
        XCTAssertEqual(html, .unavailable(.notVideo))
        XCTAssertEqual(nestedPlaylist, .unavailable(.notVideo))
    }

    func testErrorsMapToUserFacingStates() async {
        let expired = await validate("/expired/video.mp4")
        let missing = await validate("/missing.mp4")
        let html = await validate("/html/video.mp4")
        XCTAssertEqual(expired, .unavailable(.expiredLink))
        XCTAssertEqual(missing, .unavailable(.notFound))
        XCTAssertEqual(html, .unavailable(.notVideo))
    }

    func testCookieScopedProbe() async {
        let cookie = HTTPCookie(properties: [.name: "session", .value: "ok", .domain: "127.0.0.1", .path: "/"])!
        let status = await validate("/cookie/video.mp4", context: RequestContext(cookies: [cookie], userAgent: nil, referer: nil))
        XCTAssertTrue(status.isReady)
    }

    func testStreamThatNeedsRefererUsesRelay() async {
        let context = RequestContext(cookies: [], userAgent: nil, referer: server.url("/page/basic.html"))
        let status = await validate("/hls/referer-master.m3u8", kind: .hls, context: context)
        guard case .ready(let probe) = status else { return XCTFail("Expected ready Referer-only HLS: \(status)") }
        XCTAssertTrue(probe.requiresReferer)
        let fileStatus = await validate("/referer/video.mp4", kind: .video, context: context)
        XCTAssertTrue(fileStatus.isReady, "direct downloads do send the Referer")
    }
}
