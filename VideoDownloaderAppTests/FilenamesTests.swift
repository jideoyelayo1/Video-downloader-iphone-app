import XCTest
@testable import VideoDownloaderApp

final class FilenamesTests: XCTestCase {
    let id = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
    var suffix: String { "-\(id.uuidString)" }

    private func title(of name: String) -> String {
        let withoutExt = (name as NSString).deletingPathExtension
        XCTAssertTrue(withoutExt.hasSuffix(suffix))
        return String(withoutExt.dropLast(suffix.count))
    }

    func testBasicName() {
        XCTAssertEqual(Filenames.safe(title: "My Video", extension: "MP4", id: id), "My Video-\(id.uuidString).mp4")
    }

    func testStripsForbiddenAndControlCharacters() {
        let name = Filenames.safe(title: "a/b\\c:d?e%f*g|h\"i<j>k\u{0}l\u{7}m\u{202E}n", extension: "mov", id: id)
        XCTAssertEqual(title(of: name), "abcdefghijk l m n")
        XCTAssertFalse(name.contains("/"))
    }

    func testPathTraversalSanitised() {
        let name = Filenames.safe(title: "../../etc/passwd", extension: "mp4", id: id)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.hasPrefix("."))
        XCTAssertEqual(title(of: name), "etcpasswd")
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(title(of: Filenames.safe(title: "  Hello \n\t  World  ", extension: "mp4", id: id)), "Hello World")
    }

    func testEmptyTitleBecomesVideo() {
        XCTAssertEqual(Filenames.safe(title: "", extension: "mp4", id: id), "video-\(id.uuidString).mp4")
        XCTAssertEqual(title(of: Filenames.safe(title: "/// ??? ...", extension: "mp4", id: id)), "video")
    }

    func testTruncatesTo120CharactersWithoutSplittingGraphemes() {
        XCTAssertEqual(title(of: Filenames.safe(title: String(repeating: "a", count: 200), extension: "mp4", id: id)).count, 120)
        // Multi-byte titles are also capped by bytes so the whole name stays under APFS's 255-byte limit.
        let accented = title(of: Filenames.safe(title: String(repeating: "é", count: 200), extension: "mp4", id: id))
        XCTAssertEqual(accented.utf8.count, Filenames.maxTitleBytes)
        XCTAssertTrue(accented.allSatisfy { $0 == "é" })
        let family = "👨‍👩‍👧‍👦"
        let emoji = title(of: Filenames.safe(title: String(repeating: family, count: 150), extension: "mp4", id: id))
        XCTAssertFalse(emoji.isEmpty)
        XCTAssertTrue(emoji.allSatisfy { String($0) == family })
        XCTAssertLessThanOrEqual(Filenames.safe(title: String(repeating: family, count: 150), extension: "mp4", id: id).utf8.count, 255)
        let mixed = title(of: Filenames.safe(title: String(repeating: "a", count: 119) + "🇬🇧xyz", extension: "mp4", id: id))
        XCTAssertEqual(mixed.count, 120)
        XCTAssertTrue(mixed.hasSuffix("🇬🇧"))
    }

    func testBadExtensionFallsBackToMP4() {
        XCTAssertTrue(Filenames.safe(title: "x", extension: "", id: id).hasSuffix(".mp4"))
        XCTAssertTrue(Filenames.safe(title: "x", extension: "toolong", id: id).hasSuffix(".mp4"))
        XCTAssertTrue(Filenames.safe(title: "x", extension: "m/v", id: id).hasSuffix(".mp4"))
        XCTAssertTrue(Filenames.safe(title: "x", extension: "mp٤", id: id).hasSuffix(".mp4"))
        XCTAssertTrue(Filenames.safe(title: "x", extension: "WebM", id: id).hasSuffix(".webm"))
        XCTAssertTrue(Filenames.safe(title: "x", extension: "3gp", id: id).hasSuffix(".3gp"))
    }

    func testFileExtensionPriority() {
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: "clip.MOV", url: URL(string: "https://a.com/v.webm"), mimeType: "video/x-matroska"), "mov")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: URL(string: "https://a.com/v.webm?x=1"), mimeType: "video/mp4"), "webm")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: "download", url: URL(string: "https://a.com/stream"), mimeType: "video/x-matroska"), "mkv")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: "watch.php", url: URL(string: "https://a.com/watch.php"), mimeType: "video/quicktime"), "mov")
    }

    func testFileExtensionFromMIME() {
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: "video/mp4"), "mp4")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: "video/quicktime"), "mov")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: "VIDEO/WEBM; codecs=vp9"), "webm")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: "video/x-matroska"), "mkv")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: "video/mp2t"), "ts")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: "application/octet-stream"), "mp4")
        XCTAssertEqual(Filenames.fileExtension(suggestedFilename: nil, url: nil, mimeType: nil), "mp4")
    }
}
