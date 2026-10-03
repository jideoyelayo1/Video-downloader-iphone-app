import XCTest
@testable import VideoDownloaderApp

final class HLSManifestTests: XCTestCase {
    let base = URL(string: "https://cdn.example.com/show/ep1/master.m3u8?token=abc")!

    func testMasterWithQuotedCodecsAndRelativeURIs() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=640x360,FRAME-RATE=30
        low/index.m3u8

        #EXT-X-STREAM-INF:CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,BANDWIDTH=5000000,AUDIO="aud,1"
        # a comment between tag and URI
        /abs/hi.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="iframe.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        https://other.example.net/mid.m3u8
        """
        guard case .master(let variants) = HLSManifest.parse(text, baseURL: base) else { return XCTFail("expected master") }
        XCTAssertEqual(variants.map(\.bandwidth), [5_000_000, 2_500_000, 800_000])
        XCTAssertEqual(variants.map(\.url.absoluteString), ["https://cdn.example.com/abs/hi.m3u8", "https://other.example.net/mid.m3u8",
                                                           "https://cdn.example.com/show/ep1/low/index.m3u8"])
        XCTAssertEqual(variants.map(\.resolution), ["1920x1080", "1280x720", "640x360"])
        XCTAssertEqual(variants.map(\.qualityLabel), ["1080p", "720p", "360p"])
    }

    func testMasterVariantWithoutBandwidthSortsLast() {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1x2\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=100\nb.m3u8\n"
        guard case .master(let variants) = HLSManifest.parse(text, baseURL: base) else { return XCTFail() }
        XCTAssertEqual(variants.map(\.bandwidth), [100, nil])
    }

    func testQualityLabelFallbacks() {
        let url = URL(string: "https://a.com/x.m3u8")!
        XCTAssertEqual(HLSVariant(url: url, bandwidth: 1_500_000, resolution: nil).qualityLabel, "1500 kbps")
        XCTAssertEqual(HLSVariant(url: url, bandwidth: nil, resolution: nil).qualityLabel, "Auto")
        XCTAssertEqual(HLSVariant(url: url, bandwidth: 1000, resolution: "garbage").qualityLabel, "1 kbps")
        XCTAssertEqual(HLSVariant(url: url, bandwidth: nil, resolution: "3840x2160").qualityLabel, "2160p")
    }

    func testFiniteVODMediaPlaylistSumsDurations() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXTINF:9.009,
        seg0.ts
        #EXTINF:9.009,title with, comma
        seg1.ts
        #EXTINF:3.5
        seg2.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let finite, let drm, let count, let duration) = HLSManifest.parse(text, baseURL: base) else { return XCTFail() }
        XCTAssertTrue(finite)
        XCTAssertFalse(drm)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(duration, 21.518, accuracy: 0.0001)
    }

    func testPlaylistTypeVODIsFiniteWithoutEndlist() {
        let text = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4,\na.ts\n"
        XCTAssertEqual(HLSManifest.parse(text, baseURL: base), .media(isFinite: true, isEncryptedWithDRM: false, segmentCount: 1, totalDuration: 4))
    }

    func testLivePlaylistIsNotFinite() {
        let text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:1234\n#EXTINF:6.0,\nlive1234.ts\n#EXTINF:6.0,\nlive1235.ts\n"
        XCTAssertEqual(HLSManifest.parse(text, baseURL: base), .media(isFinite: false, isEncryptedWithDRM: false, segmentCount: 2, totalDuration: 12))
        let event = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXTINF:6.0,\na.ts\n"
        guard case .media(let finite, _, _, _) = HLSManifest.parse(event, baseURL: base) else { return XCTFail() }
        XCTAssertFalse(finite)
    }

    private func isDRM(_ keyLine: String) -> Bool {
        let text = "#EXTM3U\n\(keyLine)\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n"
        guard case .media(_, let drm, _, _) = HLSManifest.parse(text, baseURL: base) else { XCTFail(); return false }
        return drm
    }

    func testAES128IsNotDRM() {
        XCTAssertFalse(isDRM("#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example.com/k?id=1,2\",IV=0x1234"))
        XCTAssertFalse(isDRM("#EXT-X-KEY:METHOD=NONE"))
    }

    func testSampleAESIsDRM() {
        XCTAssertTrue(isDRM("#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"https://keys.example.com/k\""))
        XCTAssertTrue(isDRM("#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"data:text/plain;base64,AAAA\",KEYFORMAT=\"urn:uuid:edef8ba9\""))
    }

    func testFairPlayIsDRM() {
        XCTAssertTrue(isDRM("#EXT-X-KEY:METHOD=AES-128,URI=\"skd://asset-id\""))
        XCTAssertTrue(isDRM("#EXT-X-KEY:METHOD=AES-128,URI=\"https://k\",KEYFORMAT=\"com.apple.streamingkeydelivery\",KEYFORMATVERSIONS=\"1\""))
        XCTAssertTrue(isDRM("#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\""))
    }

    func testBOMAndLeadingWhitespaceAndCRLF() {
        let text = "\u{FEFF}  \r\n#EXTM3U\r\n#EXTINF:2.5,\r\na.ts\r\n#EXT-X-ENDLIST\r\n"
        XCTAssertEqual(HLSManifest.parse(text, baseURL: base), .media(isFinite: true, isEncryptedWithDRM: false, segmentCount: 1, totalDuration: 2.5))
    }

    func testNonM3UReturnsNil() {
        XCTAssertNil(HLSManifest.parse("<!doctype html><html></html>", baseURL: base))
        XCTAssertNil(HLSManifest.parse("", baseURL: base))
        XCTAssertNil(HLSManifest.parse("#EXTINF:4,\na.ts\n#EXTM3U", baseURL: base))
    }

    func testAttributeParser() {
        let attrs = HLSManifest.attributes(of: "#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"a,b\",RESOLUTION=2x3,NAME=\"x=y\"")
        XCTAssertEqual(attrs["BANDWIDTH"], "1")
        XCTAssertEqual(attrs["CODECS"], "a,b")
        XCTAssertEqual(attrs["RESOLUTION"], "2x3")
        XCTAssertEqual(attrs["NAME"], "x=y")
    }

    func testRenditionURLsIncludeAudioSubtitleAndIFramePlaylists() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",URI="audio/english.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English, SDH",URI="https://subs.example/en.m3u8"
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC",INSTREAM-ID="CC1"
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,URI="../trick/iframes.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="audio",SUBTITLES="subs"
        video.m3u8
        """
        let base = URL(string: "https://cdn.example/_v7/abc/master.m3u8")!
        XCTAssertEqual(HLSManifest.renditionURLs(in: master, baseURL: base).map(\.absoluteString), [
            "https://cdn.example/_v7/abc/audio/english.m3u8",
            "https://subs.example/en.m3u8",
            "https://cdn.example/_v7/trick/iframes.m3u8"
        ])
        XCTAssertTrue(HLSManifest.renditionURLs(in: "#EXTM3U\n#EXTINF:4,\nseg.ts\n", baseURL: base).isEmpty)
    }

    func testQualitySizesAreEstimatedFromBandwidthAndLength() {
        let variant = HLSVariant(url: URL(string: "https://cdn.example/720.m3u8")!, bandwidth: 2_000_000, resolution: "1280x720")
        XCTAssertEqual(variant.estimatedBytes(duration: 1_440), 360_000_000)
        XCTAssertTrue(variant.menuTitle(duration: 1_440).hasPrefix("720p · about "), variant.menuTitle(duration: 1_440))
        XCTAssertEqual(variant.menuTitle(duration: nil), "720p")
        XCTAssertNil(HLSVariant(url: variant.url, bandwidth: nil, resolution: nil).estimatedBytes(duration: 100))
    }
}
