import XCTest
@testable import VideoDownloaderApp

@MainActor
final class DiagnosticsLogTests: XCTestCase {
    func testLogPersistsAndRedactsSignedURLs() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = DiagnosticsLog(fileURL: file)
        first.record(event: "download-error", url: "https://name:secret@example.com/video.m3u8?token=private#part",
                     note: "Failed at https://example.com/segment.ts?signature=private")
        let exported = try String(contentsOf: first.exportFile(), encoding: .utf8)
        XCTAssertTrue(exported.contains("HTTP") == false)
        XCTAssertTrue(exported.contains("https://example.com/video.m3u8"))
        XCTAssertFalse(exported.contains("private"))
        XCTAssertFalse(exported.contains("secret"))

        let second = DiagnosticsLog(fileURL: file)
        XCTAssertTrue(second.text.contains("download-error"))
        XCTAssertFalse(second.text.contains("private"))
        second.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFullLogCompactsInBatchesAndReloadsLatestEntries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = DiagnosticsLog(fileURL: file)
        for index in 0..<1_150 {
            log.record(event: "test-\(index)", url: "https://example.com/video.mp4")
        }
        XCTAssertEqual(log.entries.count, DiagnosticsLog.maxEntries)
        log.flush()
        let persistedLines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertLessThan(persistedLines.count, DiagnosticsLog.maxEntries + 100)
        let reloaded = DiagnosticsLog(fileURL: file)
        XCTAssertTrue(reloaded.text.contains("test-1149"))
        XCTAssertFalse(reloaded.text.contains("test-0]"))
    }

    func testLineFormatIncludesFrameTypeAndRedactedNote() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = DiagnosticsLog(fileURL: file)
        log.record(event: "media", url: "https://cdn.example/master.m3u8?token=1", frameURL: URL(string: "https://player.example/e/1?x=2"),
                   isMainFrame: false, contentType: "application/vnd.apple.mpegurl", note: "xhr → https://cdn.example/a?b=c")
        let line = try XCTUnwrap(log.entries.last?.line)
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \[media\] frame https://cdn\.example/master\.m3u8 type=application/vnd\.apple\.mpegurl — xhr → https://cdn\.example/a \(frame: https://player\.example/e/1\)$"#
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), line)
        log.flush()
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(line))
    }

    func testClearDiscardsQueuedWritesAndLaterEntriesStartANewFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = DiagnosticsLog(fileURL: file)
        for index in 0..<200 { log.record(event: "burst-\(index)", url: "https://example.com/\(index).ts") }
        log.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        log.record(event: "after-clear", url: "https://example.com/next.m3u8")
        log.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("[after-clear]"))
    }

    func testPreviousSessionLinesKeepTheirText() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = DiagnosticsLog(fileURL: file)
        first.record(event: "pip", url: "app://player", note: "Started")
        let line = first.entries.last!.line
        let second = DiagnosticsLog(fileURL: file)
        let previous = second.entries.first { $0.line == line }
        XCTAssertEqual(previous?.isPreviousSession, true)
        XCTAssertFalse(second.entries.last!.isPreviousSession)
    }
}
