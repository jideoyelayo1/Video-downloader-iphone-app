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
}
