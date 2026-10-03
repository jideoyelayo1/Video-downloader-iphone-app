import AVFoundation
import SwiftData
import XCTest
@testable import VideoDownloaderApp

/// Site subtitles moved into the video file, so iOS lists and draws them itself (including in
/// Picture in Picture and on AirPlay).
@MainActor
final class SubtitleRemuxerTests: XCTestCase {
    private func fixture(_ name: String = "fixture.mp4") throws -> URL {
        let source = try XCTUnwrap(FixtureSet.resourceURL(named: name, in: Bundle(for: LocalMediaServer.self)))
        let copy = DownloadStorage.libraryDirectory.appendingPathComponent("remux-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: source, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy
    }

    /// The text of the subtitle samples in a track, in order, skipping the empty gap samples.
    private func texts(in track: AVAssetTrack, of asset: AVAsset) throws -> [String] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var texts: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard data.count > 2 else { continue }
            let text = String(decoding: data.dropFirst(2), as: UTF8.self)
            if !text.isEmpty { texts.append(text) }
        }
        return texts
    }

    func testSubtitlesBecomeTracksOfTheVideo() async throws {
        let source = try fixture()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let english = SubtitleRemuxer.Track(language: "en", name: "English",
                                            cues: [SubtitleCue(start: 0.5, end: 2, text: "Hello"), SubtitleCue(start: 2.5, end: 4, text: "Second line")])
        let spanish = SubtitleRemuxer.Track(language: "es", name: "Español", cues: [SubtitleCue(start: 0.5, end: 2, text: "Línea de prueba & más")])
        try await SubtitleRemuxer.remux(source, adding: [english, spanish], defaultTrack: 0, to: output)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 5, accuracy: 0.5)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty, "the video is copied")
        let group = try await XCTUnwrapAsync(try await asset.loadMediaSelectionGroup(for: .legible))
        XCTAssertEqual(Set(group.options.compactMap(\.extendedLanguageTag)), ["en", "es"], "iOS lists both languages")
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(try texts(in: tracks[0], of: asset), ["Hello", "Second line"])
        XCTAssertEqual(try texts(in: tracks[1], of: asset), ["Línea de prueba & más"])
        let verified = try await SubtitleEmbedder.verify(output, matches: source, subtitleTracks: 2)
        XCTAssertTrue(verified)
    }

    /// A finished download with saved site subtitles is rewritten as a .mov with them inside.
    func testDownloadsWithSiteSubtitlesAreRewritten() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let container = try LibrarySchema.container(inMemory: true)
        let source = try fixture()
        let item = DownloadItem(title: "Site Subtitles", remoteURL: server.url("/video.mp4"), sourcePageURL: server.url("/page/tracks.html"),
                                kind: .video, status: .completed)
        item.localFileName = source.lastPathComponent
        container.mainContext.insert(item)
        let tracks = [SubtitleTrack(url: server.url("/subs/en.vtt"), label: "English", language: "en", isDefault: true, referer: nil),
                      SubtitleTrack(url: server.url("/subs/es.vtt"), label: "Español", language: "es", isDefault: false, referer: nil)]
        let saved = await SubtitleStore.save(tracks, for: item.id) { _ in nil }
        XCTAssertEqual(saved.count, 2)
        defer { SubtitleStore.remove(for: item.id) }

        let embedder = SubtitleEmbedder(context: container.mainContext)
        let embedded = await embedder.embed(item)
        XCTAssertTrue(embedded)
        let fileName = try XCTUnwrap(item.localFileName)
        XCTAssertTrue(fileName.hasSuffix(".mov"), fileName)
        let file = try XCTUnwrap(item.localURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the original is replaced")
        XCTAssertTrue(SubtitleStore.saved(for: item.id).isEmpty, "the subtitles now live in the video")
        let group = try await XCTUnwrapAsync(try await AVURLAsset(url: file).loadMediaSelectionGroup(for: .legible))
        // AVFoundation adds a forced-only variant of each subtitle track, which players hide.
        let full = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        XCTAssertEqual(full.map(\.extendedLanguageTag), ["en", "es"], group.options.map(\.displayName).joined(separator: ", "))
        XCTAssertFalse(full.contains { $0.displayName.contains(" - ") }, "named by language alone")
        let again = await embedder.embed(item)
        XCTAssertFalse(again, "nothing left to add")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
