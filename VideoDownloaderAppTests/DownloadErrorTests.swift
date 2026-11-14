import XCTest
@testable import VideoDownloaderApp

final class DownloadErrorTests: XCTestCase {
    func testStatusCodeMapping() {
        XCTAssertNil(DownloadError.from(statusCode: 200))
        XCTAssertNil(DownloadError.from(statusCode: 206))
        XCTAssertEqual(DownloadError.from(statusCode: 401), .expiredLink)
        XCTAssertEqual(DownloadError.from(statusCode: 403), .expiredLink)
        XCTAssertEqual(DownloadError.from(statusCode: 410), .expiredLink)
        XCTAssertEqual(DownloadError.from(statusCode: 404), .notFound)
        XCTAssertEqual(DownloadError.from(statusCode: 500), .httpStatus(500))
        XCTAssertEqual(DownloadError.from(statusCode: 429), .rateLimited)
        XCTAssertEqual(DownloadError.from(statusCode: 304), .httpStatus(304))
    }

    func testURLErrorMapping() {
        XCTAssertEqual(DownloadError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DownloadError.from(URLError(.networkConnectionLost)), .networkLost)
        XCTAssertEqual(DownloadError.from(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(DownloadError.from(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(DownloadError.from(URLError(.cannotWriteToFile)), .insufficientStorage(required: nil, available: nil))
        if case .other = DownloadError.from(URLError(.badServerResponse)) {} else { XCTFail() }
    }

    func testStreamServerStatusCodesKeepTheirMeaning() {
        func coreMedia(_ text: String) -> Error {
            NSError(domain: "CoreMediaErrorDomain", code: -12660, userInfo: [NSLocalizedDescriptionKey: text])
        }
        XCTAssertEqual(DownloadError.from(coreMedia("HTTP 403: Forbidden")), .expiredLink)
        XCTAssertEqual(DownloadError.from(coreMedia("HTTP 404: File Not Found")), .notFound)
        XCTAssertEqual(DownloadError.from(coreMedia("HTTP 429: Too Many Requests")), .rateLimited)
        XCTAssertEqual(DownloadError.from(coreMedia("HTTP 503: Service Unavailable")), .httpStatus(503))
        XCTAssertEqual(DownloadError.from(coreMedia("Cannot Open")), .other("Cannot Open"))
    }

    func testOnlyDroppedConnectionsAndBusyServersAreRetriedAutomatically() {
        XCTAssertTrue(DownloadError.networkLost.isTransient)
        XCTAssertTrue(DownloadError.timedOut.isTransient)
        XCTAssertTrue(DownloadError.offline.isTransient)
        XCTAssertTrue(DownloadError.httpStatus(502).isTransient)
        XCTAssertFalse(DownloadError.httpStatus(418).isTransient)
        XCTAssertFalse(DownloadError.expiredLink.isTransient, "needs a fresh link from the page")
        XCTAssertFalse(DownloadError.rateLimited.isTransient, "retrying soon makes it worse")
        XCTAssertFalse(DownloadError.insufficientStorage(required: nil, available: nil).isTransient)
    }

    func testDiskFullErrors() {
        XCTAssertEqual(DownloadError.from(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), .insufficientStorage(required: nil, available: nil))
        XCTAssertEqual(DownloadError.from(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .insufficientStorage(required: nil, available: nil))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
        XCTAssertEqual(DownloadError.from(wrapped), .insufficientStorage(required: nil, available: nil))
    }

    func testPassthroughAndFallback() {
        XCTAssertEqual(DownloadError.from(DownloadError.liveStream), .liveStream)
        XCTAssertEqual(DownloadError.from(CancellationError()), .cancelled)
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        XCTAssertEqual(DownloadError.from(error), .other("Boom"))
        let hls500 = NSError(domain: "CoreMediaErrorDomain", code: -16847,
                             userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (HTTP 500: Internal Server Error)"])
        XCTAssertTrue(DownloadError.from(hls500).message.contains("Replay the episode"))
        let hls429 = NSError(domain: "CoreMediaErrorDomain", code: -16845,
                             userInfo: [NSLocalizedDescriptionKey: "HTTP 429: (unhandled)"])
        XCTAssertEqual(DownloadError.from(hls429), .rateLimited)
    }

    func testStorageCheckUsesSafetyMargin() {
        let mb: Int64 = 1024 * 1024
        XCTAssertNil(DownloadError.storageCheck(expectedBytes: 100 * mb, availableBytes: 300 * mb))
        XCTAssertNil(DownloadError.storageCheck(expectedBytes: 100 * mb, availableBytes: 300 * mb + 1))
        XCTAssertEqual(DownloadError.storageCheck(expectedBytes: 100 * mb, availableBytes: 300 * mb - 1), .insufficientStorage(required: 300 * mb, available: 300 * mb - 1))
        XCTAssertEqual(DownloadError.storageCheck(expectedBytes: 1000 * mb, availableBytes: 500 * mb), .insufficientStorage(required: 1200 * mb, available: 500 * mb))
        XCTAssertNil(DownloadError.storageCheck(expectedBytes: 1000 * mb, availableBytes: nil))
        XCTAssertNil(DownloadError.storageCheck(expectedBytes: nil, availableBytes: 250 * mb))
        XCTAssertEqual(DownloadError.storageCheck(expectedBytes: nil, availableBytes: 50 * mb), .insufficientStorage(required: 200 * mb, available: 50 * mb))
        XCTAssertNil(DownloadError.storageCheck(expectedBytes: -1, availableBytes: 250 * mb))
    }

    func testMessagesAreShortAndActionable() {
        let all: [DownloadError] = [.expiredLink, .notFound, .httpStatus(503), .notVideo, .streamSegment, .hlsPlaylistAsFile, .protectedStream, .liveStream,
                                    .insufficientStorage(required: nil, available: nil), .insufficientStorage(required: 2_000_000_000, available: 1_000_000_000),
                                    .offline, .networkLost, .timedOut, .cancelled]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertLessThan(error.message.count, 120, error.message)
        }
        XCTAssertEqual(DownloadError.expiredLink.message, "The link expired. Replay the video in Browse and download again.")
        XCTAssertTrue(DownloadError.httpStatus(503).message.contains("503"))
        XCTAssertTrue(DownloadError.insufficientStorage(required: 2_000_000_000, available: 1_000_000_000).message.contains("GB"))
        XCTAssertEqual(DownloadError.other("Custom").message, "Custom")
    }

    func testResponseValidationFailures() {
        XCTAssertNil(DownloadResponseValidation.failure(statusCode: 200, mimeType: "video/mp4"))
        XCTAssertNil(DownloadResponseValidation.failure(statusCode: 206, mimeType: "application/octet-stream"))
        XCTAssertNil(DownloadResponseValidation.failure(statusCode: 200, mimeType: nil))
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 403, mimeType: "text/html"), .expiredLink)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 404, mimeType: "video/mp4"), .notFound)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 503, mimeType: "video/mp4"), .httpStatus(503))
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "application/vnd.apple.mpegurl"), .hlsPlaylistAsFile)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "application/octet-stream", prefixData: Data("\n#EXTM3U\n".utf8)), .hlsPlaylistAsFile)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "text/html"), .notVideo)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "application/json"), .notVideo)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "video/mp4", prefixData: Data("<!DOCTYPE html>".utf8)), .notVideo)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "image/png"), .notVideo)
        XCTAssertEqual(DownloadResponseValidation.failureMessage(statusCode: 403, mimeType: nil), DownloadError.expiredLink.message)
        XCTAssertNil(DownloadResponseValidation.failureMessage(statusCode: 200, mimeType: "video/webm"))
    }

    func testDASHAndScrambledPlaylistsGetTheirOwnReasons() {
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "application/dash+xml"), .dashStream)
        let mpd = Data(#"<?xml version="1.0" encoding="utf-8"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011">"#.utf8)
        XCTAssertEqual(DownloadResponseValidation.failure(statusCode: 200, mimeType: "application/octet-stream", prefixData: mpd), .dashStream)
        XCTAssertEqual(DownloadResponseValidation.playlistFailure(mimeType: "application/dash+xml", data: mpd), .dashStream)
        // Some players answer their playlist URL as mpegurl with an encoded body.
        XCTAssertEqual(DownloadResponseValidation.playlistFailure(mimeType: "application/vnd.apple.mpegurl", data: Data("lOd3dA1id49b7zjrlyMAkfBq".utf8)), .scrambledStream)
        XCTAssertEqual(DownloadResponseValidation.playlistFailure(mimeType: "text/html", data: Data("<!doctype html><p>blocked".utf8)), .notVideo)
        XCTAssertEqual(DownloadResponseValidation.playlistFailure(mimeType: "application/vnd.apple.mpegurl", data: Data(#"{"error":"expired"}"#.utf8)), .notVideo)
        XCTAssertEqual(DownloadResponseValidation.playlistFailure(mimeType: "application/vnd.apple.mpegurl", data: Data()), .notVideo)
        XCTAssertTrue(DownloadError.dashStream.message.contains("DASH"))
        XCTAssertTrue(DownloadError.scrambledStream.message.contains("scrambles"))
    }
}
