import AVFoundation
import Network
import XCTest
@testable import VideoDownloaderApp

final class CastMediaServerTests: XCTestCase {
    /// Patterned so a wrong offset can't line up with the right bytes at a chunk boundary.
    private static let video = Data((0..<3_000_000).map { UInt8($0 % 251) })
    private let subtitle = Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n".utf8)
    private var videoURL: URL!
    private var server: CastMediaServer!
    private var base: URL!
    private var session: URLSession!

    override func setUp() async throws {
        videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Self.video.write(to: videoURL)
        server = try CastMediaServer(host: "127.0.0.1", allowedPeers: [.loopback], video: videoURL,
                                     extras: ["subtitles/0.vtt": .init(type: "text/vtt", data: subtitle)]) { _ in }
        base = try await server.start()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        server?.stop()
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
    }

    private func fetch(_ path: String, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testServesTheWholeVideoWithTheHeadersAChromecastNeeds() async throws {
        let (data, response) = try await fetch("video.mp4")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Self.video, "every chunk, in order")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "3000000")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
    }

    func testHeadSendsTheLengthWithoutTheBody() async throws {
        let (data, response) = try await fetch("video.mp4", method: "HEAD")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "3000000")
    }

    func testServesByteRanges() async throws {
        var (data, response) = try await fetch("video.mp4", headers: ["Range": "bytes=100-199"])
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/3000000")
        XCTAssertEqual(data, Self.video[100..<200])
        (data, response) = try await fetch("video.mp4", headers: ["Range": "bytes=-10"])
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 2999990-2999999/3000000")
        XCTAssertEqual(data, Self.video.suffix(10))
        (data, response) = try await fetch("video.mp4", headers: ["Range": "bytes=2999990-"])
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(data, Self.video.suffix(10))
        (data, response) = try await fetch("video.mp4", headers: ["Range": "bytes=9999999-"])
        XCTAssertEqual(response.statusCode, 416)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes */3000000")
    }

    func testServesOnlyTheFilesInItsTable() async throws {
        for path in ["/wrong-token/video.mp4", "other.mp4", "../video.mp4", "%2E%2E/video.mp4", "/"] {
            let status = try await fetch(path).1.statusCode
            XCTAssertEqual(status, 404, path)
        }
        let post = try await fetch("video.mp4", method: "POST").1.statusCode
        XCTAssertEqual(post, 405)
    }

    func testAnswersACORSPreflight() async throws {
        let response = try await fetch("subtitles/0.vtt", method: "OPTIONS").1
        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Methods"), "GET, HEAD")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
    }

    func testServesSubtitlesAsWebVTT() async throws {
        let (data, response) = try await fetch("subtitles/0.vtt")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/vtt")
        XCTAssertEqual(data, subtitle)
    }

    func testTurnsSRTIntoWebVTT() {
        XCTAssertEqual(CastMediaServer.webVTT("\u{FEFF}1\n00:00:01,000 --> 00:00:02,500\nHi, there\n"),
                       "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500\nHi, there\n")
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHi\n"
        XCTAssertEqual(CastMediaServer.webVTT(vtt), vtt)
    }

    func testRefusesAnyoneButTheListedPeers() async throws {
        // URLSession retries a dropped connection; each address is reported once.
        let refused = expectation(description: "refused the phone itself")
        let strict = try CastMediaServer(host: "127.0.0.1", allowedPeers: [IPv4Address("10.0.0.1")!], video: videoURL, extras: [:]) { peer in
            if peer == "127.0.0.1" { refused.fulfill() }
        }
        defer { strict.stop() }
        let url = try await strict.start().appendingPathComponent("video.mp4")
        do {
            _ = try await session.data(from: url)
            XCTFail("a connection from an address not listed should be dropped")
        } catch {}
        await fulfillment(of: [refused], timeout: 5)
    }

    func testStopEndsServing() async throws {
        server.stop()
        do {
            _ = try await fetch("video.mp4")
            XCTFail("a stopped server shouldn't answer")
        } catch {}
    }

    func testAVFoundationPlaysTheServedVideo() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try FixtureSet.bundled().mp4.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let served = try CastMediaServer(host: "127.0.0.1", allowedPeers: [.loopback], video: fixture, extras: [:]) { _ in }
        defer { served.stop() }
        let asset = AVURLAsset(url: try await served.start().appendingPathComponent("video.mp4"))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
    }

    func testFindsThePhonesAddressOnTheDevicesNetwork() {
        XCTAssertEqual(CastMediaServer.lanAddress(near: "127.0.0.1"), "127.0.0.1")
        XCTAssertNil(CastMediaServer.lanAddress(near: "nonsense"))
    }
}
