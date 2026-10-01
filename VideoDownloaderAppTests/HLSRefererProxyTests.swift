import AVFoundation
import XCTest
@testable import VideoDownloaderApp

final class HLSRefererProxyTests: XCTestCase {
    private var server: LocalMediaServer!

    override func setUpWithError() throws {
        server = try LocalMediaServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    func testValidatorOffersRefererOnlyHLSAndRelayForwardsNestedRequests() async throws {
        let context = RequestContext(cookies: [], userAgent: "RelayFixture/1", referer: server.url("/page/basic.html"))
        let candidate = MediaCandidate(url: server.url("/hls/referer-master.m3u8"),
                                       sourcePageURL: server.url("/page/basic.html"), kind: .hls)
        let status = await CandidateValidator().validate(candidate, context: context)
        guard case .ready(let probe) = status else { return XCTFail("Expected the Referer-only stream to be downloadable: \(status)") }
        XCTAssertTrue(probe.requiresReferer)
        XCTAssertEqual(probe.variants.count, 1)

        let proxy = try HLSRefererProxy(context: context)
        defer { proxy.stop() }
        let localMaster = try proxy.start(for: candidate.url)
        let (masterData, masterResponse) = try await URLSession.shared.data(from: localMaster)
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.statusCode, 200)
        let master = String(decoding: masterData, as: UTF8.self)
        let localMedia = try XCTUnwrap(master.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") }).flatMap { URL(string: String($0)) })
        XCTAssertEqual(localMedia.host, "127.0.0.1")
        let (mediaData, _) = try await URLSession.shared.data(from: localMedia)
        let media = String(decoding: mediaData, as: UTF8.self)
        let localSegment = try XCTUnwrap(media.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") }).flatMap { URL(string: String($0)) })
        let (segment, _) = try await URLSession.shared.data(from: localSegment)
        XCTAssertEqual(segment, server.fixtures.hlsSegments["fixture_seg0.ts"])
        for path in ["/hls/referer-master.m3u8", "/hls/referer-media.m3u8", "/hls/referer-seg0.ts"] {
            XCTAssertEqual(server.requests(to: path).last?.header("referer"), context.referer?.absoluteString)
            XCTAssertEqual(server.requests(to: path).last?.header("user-agent"), "RelayFixture/1")
        }
    }

    func testPlaylistRewriteIncludesCaptionAndMapURIs() throws {
        let source = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,URI="../captions/en.m3u8",NAME="English"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg-0.m4s
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://video.example.com/ep/1080/index.m3u8")!
        var originals: [URL] = []
        let output = HLSRefererProxy.rewritePlaylist(source, baseURL: base) { url in
            originals.append(url)
            return URL(string: "http://127.0.0.1:9999/\(originals.count)")!
        }
        XCTAssertEqual(originals.map(\.absoluteString), [
            "https://video.example.com/ep/captions/en.m3u8",
            "https://video.example.com/ep/1080/init.mp4",
            "https://video.example.com/ep/1080/seg-0.m4s"
        ])
        XCTAssertTrue(output.contains("URI=\"http://127.0.0.1:9999/1\""))
        XCTAssertTrue(output.contains("http://127.0.0.1:9999/3"))
    }

    func testAVFoundationCanReadRelayedHLS() async throws {
        let context = RequestContext(cookies: [], userAgent: "RelayFixture/1", referer: server.url("/page/basic.html"))
        let proxy = try HLSRefererProxy(context: context)
        defer { proxy.stop() }
        let url = try proxy.start(for: server.url("/hls/referer-master.m3u8"))
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertNotNil(server.requests(to: "/hls/referer-media.m3u8").last)
    }

    func testRelayServesSeparateAudioRendition() async throws {
        let context = RequestContext(cookies: [], userAgent: "RelayFixture/1", referer: server.url("/page/basic.html"))
        let proxy = try HLSRefererProxy(context: context)
        defer { proxy.stop() }
        let localMaster = try proxy.start(for: server.url("/hls/separate-audio-master.m3u8"))
        let (masterData, _) = try await URLSession.shared.data(from: localMaster)
        let master = String(decoding: masterData, as: UTF8.self)
        let audioLine = try XCTUnwrap(master.components(separatedBy: .newlines).first { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") })
        let audioURL = try XCTUnwrap(HLSManifest.attributes(of: audioLine)["URI"].flatMap(URL.init(string:)))
        XCTAssertEqual(audioURL.host, "127.0.0.1")
        let (playlistData, _) = try await URLSession.shared.data(from: audioURL)
        let audioPlaylist = String(decoding: playlistData, as: UTF8.self)
        let segmentLine = try XCTUnwrap(audioPlaylist.components(separatedBy: .newlines).first { !$0.isEmpty && !$0.hasPrefix("#") })
        let segmentURL = try XCTUnwrap(URL(string: segmentLine))
        let (audioData, _) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual(audioData, server.fixtures.hlsAudioOnly)
        XCTAssertEqual(server.requests(to: "/hls/audio-only.ts").last?.header("referer"), context.referer?.absoluteString)
    }

    func testRepeatedPlaylistFetchesReuseRoutes() async throws {
        let context = RequestContext(cookies: [], userAgent: "RelayFixture/1", referer: server.url("/page/basic.html"))
        let proxy = try HLSRefererProxy(context: context)
        defer { proxy.stop() }
        let localMaster = try proxy.start(for: server.url("/hls/separate-audio-master.m3u8"))
        let (first, _) = try await URLSession.shared.data(from: localMaster)
        let (second, _) = try await URLSession.shared.data(from: localMaster)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "the same remote URL keeps the same relay route")
    }

    func testStoppedRelayIsReleased() async throws {
        weak var weakProxy: HLSRefererProxy?
        do {
            let context = RequestContext(cookies: [], userAgent: "RelayFixture/1", referer: server.url("/page/basic.html"))
            let proxy = try HLSRefererProxy(context: context)
            let local = try proxy.start(for: server.url("/hls/separate-audio-master.m3u8"))
            _ = try await URLSession.shared.data(from: local)
            proxy.stop()
            weakProxy = proxy
        }
        let deadline = Date().addingTimeInterval(5)
        while weakProxy != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(weakProxy, "a stopped relay must not be kept alive by its listener or connections")
    }
}
