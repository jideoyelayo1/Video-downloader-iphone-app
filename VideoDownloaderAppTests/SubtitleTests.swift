import XCTest
@testable import VideoDownloaderApp

final class SubtitleParserTests: XCTestCase {
    func testWebVTTSkipsHeaderNotesStylesAndCueSettings() {
        let vtt = "\u{FEFF}WEBVTT - Episode 1\r\n\r\nNOTE translated by fans\r\n\r\nSTYLE\r\n::cue { color: yellow }\r\n\r\n"
            + "intro\r\n00:00:01.500 --> 00:00:03.000 align:start line:90%\r\n<v Frieren><i>Hello</i> &amp; welcome</v>\r\n \r\n"
            + "01:02.000 --> 01:04.250\r\nSecond &lt;line&gt;\r\nwraps here\r\n"
        let cues = SubtitleParser.cues(from: vtt)
        XCTAssertEqual(cues, [
            SubtitleCue(start: 1.5, end: 3, text: "Hello & welcome"),
            SubtitleCue(start: 62, end: 64.25, text: "Second <line>\nwraps here")
        ])
    }

    /// ***REMOVED***'s files wrap multi-line Arabic cues in <b> that opens and closes on different lines.
    func testTagsSpanningLinesAreRemoved() {
        let vtt = "WEBVTT\n\n01:29.980 --> 01:39.740\n<b>في أقصى شمال \nالقارة</b>\n"
        XCTAssertEqual(SubtitleParser.cues(from: vtt).first?.text, "في أقصى شمال\nالقارة")
    }

    func testSRT() {
        let srt = "1\n00:00:02,000 --> 00:00:04,500\nFirst\n\n2\n00:00:05,000 --> 00:00:06,000\n<font color=\"#fff\">Second</font>\n"
        XCTAssertEqual(SubtitleParser.cues(from: srt), [
            SubtitleCue(start: 2, end: 4.5, text: "First"),
            SubtitleCue(start: 5, end: 6, text: "Second")
        ])
    }

    func testTextAtTimeJoinsOverlappingCuesAndEndsExclusively() {
        let cues = SubtitleParser.cues(from: "WEBVTT\n\n00:20.240 --> 00:29.210\nTitle\n\n00:20.240 --> 00:29.210\nSubtitle\n\n00:30.000 --> 00:31.000\nLater\n")
        XCTAssertNil(SubtitleParser.text(at: 10, in: cues))
        XCTAssertEqual(SubtitleParser.text(at: 21, in: cues), "Title\nSubtitle")
        XCTAssertNil(SubtitleParser.text(at: 29.21, in: cues))
        XCTAssertEqual(SubtitleParser.text(at: 30.5, in: cues), "Later")
    }

    func testMalformedInputYieldsNoCues() {
        XCTAssertTrue(SubtitleParser.cues(from: "<!doctype html><p>Link expired</p>").isEmpty)
        XCTAssertTrue(SubtitleParser.cues(from: "WEBVTT\n\n00:05.000 --> 00:01.000\nBackwards\n").isEmpty)
        XCTAssertNil(SubtitleParser.timestamp("1:2:3:4"))
    }
}

final class SubtitleTrackTests: XCTestCase {
    func testTracksFromDiscoveryMessage() {
        let frame = URL(string: "https://***REMOVED***/e/abc")!
        let tracks = SubtitleTrack.tracks(from: [
            "event": "subtitles", "documentURL": "https://***REMOVED***/e/abc?ep=1",
            "tracks": [
                ["url": "https://s1.***REMOVED***.top/x/sub.vtt", "label": " English ", "language": "en", "isDefault": true],
                ["url": "https://s1.***REMOVED***.top/y/sub.vtt", "label": "", "language": ""],
                ["url": "blob:https://***REMOVED***/1", "label": "Blob"]
            ]
        ], frameURL: frame)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].label, "English")
        XCTAssertEqual(tracks[0].language, "en")
        XCTAssertTrue(tracks[0].isDefault)
        XCTAssertEqual(tracks[0].referer?.absoluteString, "https://***REMOVED***/e/abc?ep=1")
        XCTAssertNil(tracks[1].language)
        XCTAssertEqual(tracks[1].displayName, "Subtitles")
        XCTAssertEqual(SubtitleTrack.displayName(label: "", language: "es"), Locale.current.localizedString(forIdentifier: "es"))
        XCTAssertEqual(SubtitleTrack.cleanLabel("Portuguese (- Portuguese(Brazil))"), "Portuguese (Brazil)")
        XCTAssertEqual(SubtitleTrack.cleanLabel("Spanish (- Spanish(Latin America))"), "Spanish (Latin America)")
        XCTAssertEqual(SubtitleTrack.cleanLabel(" English (CC) "), "English (CC)")
    }

    /// Files found by their download have no label; the name often says the language.
    func testUnlabelledTrackTakesItsLanguageFromTheFileName() {
        let languages = ["https://c.example/subs/eng.vtt", "https://c.example/en.srt", "https://c.example/English.vtt",
                         "https://c.example/sub?lang=fr", "https://c.example/sub.vtt", "https://c.example/a8f3c1.vtt",
                         "https://storage.***REMOVED***.cfd/uploads/subs/a6318f05-daa2.en.srt"]
            .map { SubtitleTrack.languageCode(in: URL(string: $0)!) }
        XCTAssertEqual(languages, ["en", "en", "en", "fr", nil, nil, "en"])
        let labelled = SubtitleTrack.tracks(from: ["tracks": [["url": "https://c.example/eng.vtt", "label": "Forced"],
                                                               ["url": "https://c.example/1.vtt", "label": "Spanish"]]], frameURL: nil)
        XCTAssertEqual(labelled.map(\.language), [nil, "es"], "a site's label wins over the file name, and names its language")
    }
}

final class SubtitleStoreTests: XCTestCase {
    private var server: LocalMediaServer!
    private var root: URL!

    override func setUpWithError() throws {
        server = try LocalMediaServer()
        try server.start()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func track(_ path: String, _ label: String, _ language: String?, isDefault: Bool = false) -> SubtitleTrack {
        SubtitleTrack(url: server.url(path), label: label, language: language, isDefault: isDefault, referer: server.url("/page/tracks.html"))
    }

    func testSavesReadableTracksSkipsExpiredOnesAndCanBeRemoved() async throws {
        let id = UUID()
        let tracks = [track("/subs/en.vtt", "English", "en", isDefault: true), track("/subs/expired.vtt", "Deutsch", "de"),
                      track("/subs/es.vtt", "Español", "es")]
        let saved = await SubtitleStore.save(tracks, for: id, in: root) { _ in RequestContext(cookies: [], userAgent: "SubtitleFixture/1", referer: nil) }
        XCTAssertEqual(saved.map(\.label), ["English", "Español"])
        XCTAssertEqual(SubtitleStore.saved(for: id, in: root), saved)
        let english = try String(contentsOf: SubtitleStore.fileURL(of: saved[0], for: id, in: root), encoding: .utf8)
        XCTAssertEqual(SubtitleParser.cues(from: english).first?.text, "Fixture English line")
        XCTAssertEqual(server.requests(to: "/subs/en.vtt").last?.header("user-agent"), "SubtitleFixture/1")

        _ = await SubtitleStore.save([track("/subs/es.vtt", "Español", "es")], for: id, in: root) { _ in nil }
        XCTAssertEqual(SubtitleStore.saved(for: id, in: root).map(\.label), ["Español"])

        SubtitleStore.remove(for: id, in: root)
        XCTAssertTrue(SubtitleStore.saved(for: id, in: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SubtitleStore.directory(for: id, in: root).path))
    }
}
