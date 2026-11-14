import XCTest
@testable import VideoDownloaderApp

final class MediaDiscoveryTests: XCTestCase {
    let page = URL(string: "https://example.com/watch")!

    func testRejectsBlobAndNonHTTPURLs() {
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "blob:https://example.com/1"], sourcePageURL: page))
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "file:///tmp/video.mp4"], sourcePageURL: page))
        XCTAssertNotNil(MediaDiscovery.candidate(from: ["url": "https://example.com/video.mp4"], sourcePageURL: page))
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://example.com/site.js", "kind": "unknown"], sourcePageURL: page))
        XCTAssertNotNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example.com/stream?id=1", "kind": "unknown", "mediaElement": true], sourcePageURL: page))
    }

    func testParsesAndInfersMediaType() {
        let candidate = MediaDiscovery.candidate(from: ["url": "https://cdn.example.com/episode.m3u8?token=1", "title": "Episode 1", "quality": "1080p"], sourcePageURL: page)
        XCTAssertEqual(candidate?.kind, .hls)
        XCTAssertEqual(candidate?.title, "Episode 1")
        XCTAssertEqual(candidate?.quality, "1080p")
    }

    func testDeduplicatesFragmentsAndKeepsDistinctStreams() {
        let first = MediaCandidate(url: URL(string: "https://cdn.example.com/video.mp4#player")!, sourcePageURL: page)
        let same = MediaCandidate(url: URL(string: "https://cdn.example.com/video.mp4#other")!, sourcePageURL: page)
        let different = MediaCandidate(url: URL(string: "https://cdn.example.com/video-720.mp4")!, sourcePageURL: page)
        XCTAssertTrue(MediaDiscovery.isDuplicate(same, in: [first]))
        XCTAssertFalse(MediaDiscovery.isDuplicate(different, in: [first]))
    }
}

final class MediaDiscoveryRulesTests: XCTestCase {
    let page = URL(string: "https://example.com/watch?ep=1")!

    func testSegmentsAreNeverOfferedAsCompleteVideos() {
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/seg-001.ts", "kind": "video"], sourcePageURL: page))
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/seg-001.m4s"], sourcePageURL: page))
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://segments.example/vd/episode/seg-57-s1080p-v1-a1.m4s", "mediaElement": true], sourcePageURL: page))
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/movie.ts", "mediaElement": true], sourcePageURL: page))
        XCTAssertNotNil(MediaDiscovery.candidate(from: ["url": "https://segments.example/vd/episode/master.m3u8"], sourcePageURL: page))
        XCTAssertNotNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/movie.mp4"], sourcePageURL: page))
    }

    func testContentTypeIdentifiesExtensionlessManifests() {
        let hls = MediaDiscovery.candidate(from: ["url": "https://cdn.example/playlist?id=9", "contentType": "application/vnd.apple.mpegurl"], sourcePageURL: page)
        XCTAssertEqual(hls?.kind, .hls)
        let file = MediaDiscovery.candidate(from: ["url": "https://cdn.example/get?id=9", "contentType": "video/mp4"], sourcePageURL: page)
        XCTAssertEqual(file?.kind, .video)
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/seg?id=9", "contentType": "video/mp2t"], sourcePageURL: page))
    }

    func testCandidateKeepsFrameContextForReferer() {
        let frame = URL(string: "https://player.example/embed/42")!
        let candidate = MediaDiscovery.candidate(from: ["url": "https://cdn.example/a.m3u8", "documentURL": frame.absoluteString],
                                                 sourcePageURL: page, frameURL: frame, isMainFrame: false)
        XCTAssertEqual(candidate?.sourcePageURL, page)
        XCTAssertEqual(candidate?.frameURL, frame)
        XCTAssertEqual(candidate?.referer, frame)
        XCTAssertEqual(candidate?.isMainFrame, false)
    }

    func testRelativeURLsAreRejectedUnlessResolved() {
        // The page script resolves against document.baseURI before posting; raw relative paths never reach Swift as valid.
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "/video.mp4"], sourcePageURL: page))
    }

    func testStaleMainFrameMessagesAreDetected() {
        let episode2 = URL(string: "https://example.com/watch?ep=2")!
        XCTAssertTrue(MediaDiscovery.isStale(documentURL: page, isMainFrame: true, currentPageURL: episode2))
        XCTAssertFalse(MediaDiscovery.isStale(documentURL: episode2.appendingPathComponent("#t=5"), isMainFrame: false, currentPageURL: episode2))
        XCTAssertFalse(MediaDiscovery.isStale(documentURL: URL(string: "https://example.com/watch?ep=2#player"), isMainFrame: true, currentPageURL: episode2))
    }
}

@MainActor
final class BrowserViewModelTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        BrowserViewModel(initialURL: nil, validator: CandidateValidator(), contextProvider: { _, _ in nil })
    }

    func testEpisodeChangeClearsCandidatesButTrivialHistoryUpdatesDoNot() {
        let model = makeModel()
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=1"), force: true)
        model.discovery.onFragment?()
        XCTAssertTrue(model.observedFragments)
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=2"), force: true)
        XCTAssertFalse(model.observedFragments)
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=1"), force: true)
        model.add(MediaCandidate(url: URL(string: "http://127.0.0.1:9/a.mp4")!, sourcePageURL: URL(string: "https://site.example/watch?ep=1")!))
        XCTAssertEqual(model.candidates.count, 1)

        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=1#comments"), force: false)
        XCTAssertEqual(model.candidates.count, 1, "fragment-only replaceState must not clear the list")

        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=2"), force: false)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertTrue(model.statuses.isEmpty)
        XCTAssertEqual(model.url?.absoluteString, "https://site.example/watch?ep=2")
    }

    func testDuplicateCandidatesAreIgnored() {
        let model = makeModel()
        let page = URL(string: "https://site.example/watch")!
        model.add(MediaCandidate(url: URL(string: "http://127.0.0.1:9/a.mp4#x")!, sourcePageURL: page))
        model.add(MediaCandidate(url: URL(string: "http://127.0.0.1:9/a.mp4#y")!, sourcePageURL: page))
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.statuses[model.candidates[0].id], .checking)
    }

    func testNavigateRejectsInvalidAddresses() {
        let model = makeModel()
        model.navigate(to: "javascript:alert(1)")
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        model.navigate(to: "example.com/page")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.addressText, "https://example.com/page")
    }
}

@MainActor
final class BrowserSessionTests: XCTestCase {
    func testRefererFollowsStrictOriginWhenCrossOrigin() {
        let frame = URL(string: "https://player.example/embed/42?token=secret")!
        XCTAssertEqual(BrowserSession.refererValue(for: frame, requesting: URL(string: "https://cdn.example/a.m3u8")!).absoluteString,
                       "https://player.example/")
        XCTAssertEqual(BrowserSession.refererValue(for: frame, requesting: URL(string: "https://player.example/v.mp4")!), frame)
    }
}

final class MediaDiscoveryAudioTests: XCTestCase {
    let page = URL(string: "https://showsite.example/anime")!

    func testAudioOnlyFilesAreNotOfferedAsVideos() {
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://audio.example/audios/jcBdahHBoSgKghASA/31830356.mp3", "mediaElement": true], sourcePageURL: page))
        XCTAssertNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/stream?id=4", "mediaElement": true, "contentType": "audio/mp4"], sourcePageURL: page))
        XCTAssertNotNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/stream?id=4", "mediaElement": true, "contentType": "video/mp4"], sourcePageURL: page))
        XCTAssertNotNil(MediaDiscovery.candidate(from: ["url": "https://cdn.example/audio/english.m3u8"], sourcePageURL: page), "HLS audio renditions are hidden behind their master instead")
    }
}
