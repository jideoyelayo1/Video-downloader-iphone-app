import XCTest
@testable import VideoDownloaderApp

/// Streams seen on bookmarked sites that can't be saved should say why.
final class CandidateValidatorReasonTests: XCTestCase {
    private var server: LocalMediaServer!

    override func setUpWithError() throws {
        server = try LocalMediaServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    func testScrambledPlaylistIsExplained() async {
        let candidate = MediaCandidate(url: server.url("/hls/scrambled.m3u8"), sourcePageURL: server.url("/page/basic.html"))
        let status = await CandidateValidator().validate(candidate, context: nil)
        XCTAssertEqual(status, .unavailable(.scrambledStream))
    }

    func testDASHManifestIsExplained() async {
        let candidate = MediaCandidate(url: server.url("/dash/manifest"), sourcePageURL: server.url("/page/basic.html"), kind: .unknown)
        let status = await CandidateValidator().validate(candidate, context: nil)
        XCTAssertEqual(status, .unavailable(.dashStream))
    }
}
