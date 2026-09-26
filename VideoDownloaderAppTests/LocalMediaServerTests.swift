import AVFoundation
import UIKit
import XCTest
@testable import VideoDownloaderApp

final class LocalMediaServerTests: XCTestCase {
    private var server: LocalMediaServer!
    private var session: URLSession!

    override func setUpWithError() throws {
        server = try LocalMediaServer()
        try server.start()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        server?.stop()
        server = nil
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private func fetch(_ path: String, method: String = "GET", headers: [String: String] = [:],
                       followRedirects: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: server.url(path))
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request, delegate: followRedirects ? nil : NoRedirect())
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func status(_ path: String, method: String = "GET", headers: [String: String] = [:]) async throws -> Int {
        try await fetch(path, method: method, headers: headers).1.statusCode
    }

    private func text(_ path: String, headers: [String: String] = [:]) async throws -> String {
        String(decoding: try await fetch(path, headers: headers).0, as: UTF8.self)
    }

    private var mp4: Data { server.fixtures.mp4 }

    func testFixturesLoadFromBundle() {
        XCTAssertGreaterThan(mp4.count, 10_000)
        XCTAssertLessThan(mp4.count, 500_000)
        XCTAssertEqual(mp4.subdata(in: 4..<8), Data("ftyp".utf8))
        XCTAssertTrue(server.fixtures.hlsMediaPlaylist.contains("#EXT-X-ENDLIST"))
        XCTAssertFalse(server.fixtures.hlsSegments.isEmpty)
        XCTAssertEqual(server.url("/video.mp4").absoluteString, "http://127.0.0.1:\(server.port!)/video.mp4")
    }

    @MainActor
    func testThumbnailsForSavedFileAndOrdinaryHLS() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try mp4.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let directData = await VideoThumbnailService.imageData(for: file, kind: .video)
        let direct = try XCTUnwrap(directData)
        XCTAssertNotNil(UIImage(data: direct))

        // This playlist has regular media segments and no I-frame-only rendition.
        let hlsData = await VideoThumbnailService.imageData(for: server.url("/hls/master.m3u8"), kind: .hls)
        let hls = try XCTUnwrap(hlsData)
        XCTAssertNotNil(UIImage(data: hls))
    }

    func testHLSCaptionTrackIsExposedForOfflineSelection() async throws {
        let asset = AVURLAsset(url: server.url("/hls/captions-master.m3u8"))
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        let option = try XCTUnwrap(group?.options.first)
        XCTAssertEqual(option.locale?.language.languageCode?.identifier, "en")
        let preferred = try await asset.load(.preferredMediaSelection)
        let selection = try XCTUnwrap(preferred.mutableCopy() as? AVMutableMediaSelection)
        selection.select(option, in: try XCTUnwrap(group))
        XCTAssertEqual(selection.selectedMediaOption(in: try XCTUnwrap(group)), option)
    }

    func testSeparateAudioIsSelectedAlongsideCaptions() async throws {
        let asset = AVURLAsset(url: server.url("/hls/separate-audio-master.m3u8"))
        let loadedAudioGroup = try await asset.loadMediaSelectionGroup(for: .audible)
        let loadedCaptionGroup = try await asset.loadMediaSelectionGroup(for: .legible)
        let audioGroup = try XCTUnwrap(loadedAudioGroup)
        let captionGroup = try XCTUnwrap(loadedCaptionGroup)
        let selections = await HLSMediaSelections.forDownload(asset: asset)
        XCTAssertEqual(selections.count, captionGroup.options.count)
        XCTAssertFalse(selections.isEmpty)
        for selection in selections {
            XCTAssertNotNil(selection.selectedMediaOption(in: audioGroup), "Every caption download must retain audio")
            XCTAssertNotNil(selection.selectedMediaOption(in: captionGroup))
        }
        let (audio, response) = try await session.data(from: server.url("/hls/audio-only.ts"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(audio, server.fixtures.hlsAudioOnly)
    }


    func testServesMP4WithHeaders() async throws {
        let (data, response) = try await fetch("/video.mp4")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), String(mp4.count))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(data, mp4)
    }

    func testHeadReturnsLengthWithoutBody() async throws {
        let (data, response) = try await fetch("/video.mp4", method: "HEAD")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.expectedContentLength, Int64(mp4.count))
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(server.requests.last?.method, "HEAD")
    }

    func testRangeRequests() async throws {
        let (first, closed) = try await fetch("/video.mp4", headers: ["Range": "bytes=0-99"])
        XCTAssertEqual(closed.statusCode, 206)
        XCTAssertEqual(closed.value(forHTTPHeaderField: "Content-Range"), "bytes 0-99/\(mp4.count)")
        XCTAssertEqual(first, mp4.prefix(100))

        let (rest, open) = try await fetch("/video.mp4", headers: ["Range": "bytes=100-"])
        XCTAssertEqual(open.statusCode, 206)
        XCTAssertEqual(open.value(forHTTPHeaderField: "Content-Range"), "bytes 100-\(mp4.count - 1)/\(mp4.count)")
        XCTAssertEqual(open.value(forHTTPHeaderField: "Content-Length"), String(mp4.count - 100))
        XCTAssertEqual(first + rest, mp4)

        let (_, invalid) = try await fetch("/video.mp4", headers: ["Range": "bytes=\(mp4.count)-"])
        XCTAssertEqual(invalid.statusCode, 416)
        XCTAssertEqual(invalid.value(forHTTPHeaderField: "Content-Range"), "bytes */\(mp4.count)")
    }

    func testByteRangeParsing() {
        XCTAssertEqual(LocalMediaServer.byteRange("bytes=0-9", length: 100), 0..<10)
        XCTAssertEqual(LocalMediaServer.byteRange("bytes=90-", length: 100), 90..<100)
        XCTAssertEqual(LocalMediaServer.byteRange("bytes=-10", length: 100), 90..<100)
        XCTAssertEqual(LocalMediaServer.byteRange("bytes=50-500", length: 100), 50..<100)
        XCTAssertNil(LocalMediaServer.byteRange("bytes=100-", length: 100))
        XCTAssertNil(LocalMediaServer.byteRange("bytes=9-3", length: 100))
        XCTAssertNil(LocalMediaServer.byteRange("items=0-1", length: 100))
    }

    func testExtensionlessStreamAndRequestRecording() async throws {
        let (data, response) = try await fetch("/noext/stream?id=1", headers: ["X-Test-Header": "abc"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(data, mp4)
        let recorded = try XCTUnwrap(server.requests(to: "/noext/stream").first)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.query, "id=1")
        XCTAssertEqual(recorded.queryItems.first?.value, "1")
        XCTAssertEqual(recorded.header("x-test-header"), "abc")
        XCTAssertEqual(recorded.header("X-TEST-HEADER"), "abc")
    }

    func testHLSPlaylistsAndSegments() async throws {
        let hlsType = "application/vnd.apple.mpegurl"
        let (master, masterResponse) = try await fetch("/hls/master.m3u8")
        XCTAssertEqual(masterResponse.value(forHTTPHeaderField: "Content-Type"), hlsType)
        let masterText = String(decoding: master, as: UTF8.self)
        XCTAssertEqual(masterText.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 2)
        XCTAssertTrue(masterText.contains("RESOLUTION=640x360"))

        let media = try await text("/hls/media.m3u8")
        XCTAssertTrue(media.contains("#EXT-X-ENDLIST"))
        let live = try await text("/hls/live.m3u8")
        XCTAssertTrue(live.contains("#EXTINF"))
        XCTAssertFalse(live.contains("#EXT-X-ENDLIST"))
        let drm = try await text("/hls/drm.m3u8")
        XCTAssertTrue(drm.contains(#"#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key""#))

        let segmentName = try XCTUnwrap(media.components(separatedBy: "\n").first { $0.hasSuffix(".ts") })
        let (segment, segmentResponse) = try await fetch("/hls/" + segmentName)
        XCTAssertEqual(segmentResponse.statusCode, 200)
        XCTAssertEqual(segmentResponse.value(forHTTPHeaderField: "Content-Type"), "video/mp2t")
        XCTAssertEqual(segment.first, 0x47) // MPEG-TS sync byte
    }

    func testCookieGating() async throws {
        let anonymous = try await status("/cookie/video.mp4")
        let wrong = try await status("/cookie/video.mp4", headers: ["Cookie": "session=bad"])
        XCTAssertEqual([anonymous, wrong], [403, 403])
        let (data, response) = try await fetch("/cookie/video.mp4", headers: ["Cookie": "a=1; session=ok"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, mp4)
    }

    func testRefererGating() async throws {
        let base = server.baseURL!.absoluteString
        let anonymous = try await status("/referer/video.mp4")
        let foreign = try await status("/referer/video.mp4", headers: ["Referer": "https://evil.example/page"])
        XCTAssertEqual([anonymous, foreign], [403, 403])
        let (data, response) = try await fetch("/referer/video.mp4", headers: ["Referer": base + "page/basic.html"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, mp4)
    }

    func testRedirects() async throws {
        let (_, raw) = try await fetch("/redirect/video.mp4", followRedirects: false)
        XCTAssertEqual(raw.statusCode, 302)
        XCTAssertEqual(raw.value(forHTTPHeaderField: "Location"), server.url("/video.mp4").absoluteString)

        let (data, followed) = try await fetch("/redirect/video.mp4")
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(followed.url?.path, "/video.mp4")
        XCTAssertEqual(data, mp4)
    }

    func testCrossHostRedirectAndCookieEcho() async throws {
        let (_, raw) = try await fetch("/redirect-cross/video.mp4", followRedirects: false)
        XCTAssertEqual(raw.statusCode, 302)
        XCTAssertEqual(raw.value(forHTTPHeaderField: "Location"), "http://localhost:\(server.port!)/echo-cookie")

        let (echo, echoResponse) = try await fetch("/echo-cookie", headers: ["Cookie": "session=ok"])
        XCTAssertEqual(echoResponse.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertEqual(String(decoding: echo, as: UTF8.self), "session=ok")
        let empty = try await text("/echo-cookie")
        XCTAssertEqual(empty, "")

        let (_, followed) = try await fetch("/redirect-cross/video.mp4")
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(followed.url?.host, "localhost")
        XCTAssertEqual(server.requests.last?.path, "/echo-cookie")
    }

    func testErrorRoutes() async throws {
        let expired = try await status("/expired/video.mp4")
        let missing = try await status("/missing.mp4")
        let unknown = try await status("/definitely/not/here")
        let post = try await status("/video.mp4", method: "POST")
        XCTAssertEqual([expired, missing, unknown, post], [410, 404, 404, 405])
        let (html, response) = try await fetch("/html/video.mp4")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).lowercased().hasPrefix("<!doctype html>"))
    }

    func testDroppedConnectionFailsDownload() async throws {
        do {
            let (data, _) = try await fetch("/drop/video.mp4")
            XCTFail("Expected a network error, got \(data.count) bytes")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
    }

    func testSlowRouteStreamsOverTime() async throws {
        let start = Date()
        let (data, response) = try await fetch("/slow/video.mp4")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, mp4)
        XCTAssertGreaterThan(elapsed, 1.5)
        XCTAssertLessThan(elapsed, 6)
    }

    func testSlowRouteCanBeCancelledMidDownload() async throws {
        let task = Task { try await fetch("/slow/video.mp4") }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch is CancellationError {}
    }

    func testPagesHaveDistinctTitles() async throws {
        var titles = Set<String>()
        for page in ["basic", "dynamic", "iframe", "hls", "links"] {
            let (data, response) = try await fetch("/page/\(page).html")
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
            let html = String(decoding: data, as: UTF8.self)
            let title = try XCTUnwrap(html.range(of: "<title>").flatMap { start in
                html.range(of: "</title>").map { String(html[start.upperBound..<$0.lowerBound]) }
            })
            titles.insert(title)
        }
        XCTAssertEqual(titles.count, 5)
        let basic = try await text("/page/basic.html")
        XCTAssertTrue(basic.contains(#"<video id="video" src="/video.mp4""#))
        let dynamic = try await text("/page/dynamic.html")
        XCTAssertTrue(dynamic.contains("/noext/stream?id=1"))
        let iframe = try await text("/page/iframe.html")
        XCTAssertTrue(iframe.contains(#"<iframe id="frame" src="/page/basic.html""#))
    }

    func testAVFoundationPlaysServedMedia() async throws {
        for path in ["/hls/master.m3u8", "/hls/media.m3u8", "/video.mp4"] {
            let asset = AVURLAsset(url: server.url(path))
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            XCTAssertTrue(playable, path)
            XCTAssertGreaterThan(duration.seconds, 4, path)
        }
    }
}
