import AVFoundation
import SwiftData

/// Moves a downloaded video's site subtitle files into the video itself (`SubtitleRemuxer`), so
/// they show in Picture in Picture and on AirPlay. Only for direct files: HLS packages can't be
/// rewritten and keep the app's subtitle overlay. The original is replaced only once the new
/// file has checked out.
@MainActor
final class SubtitleEmbedder {
    private let context: ModelContext
    var diagnostics: DiagnosticsLog?
    private var running: Set<UUID> = []

    init(context: ModelContext) {
        self.context = context
    }

    /// Off in UI tests that read the overlay's text to know where playback is.
    static var isEnabled: Bool { !LaunchOptions.flag("-KeepSiteSubtitleOverlay") }

    func embedIfNeeded(_ item: DownloadItem) {
        guard Self.isEnabled else { return }
        Task { await embed(item) }
    }

    /// Videos downloaded before subtitles were embedded.
    func embedPending() async {
        guard Self.isEnabled else { return }
        let items = (try? context.fetch(FetchDescriptor<DownloadItem>(predicate: #Predicate { $0.statusRaw == "completed" }))) ?? []
        for item in items where item.kind != .hls && !SubtitleStore.saved(for: item.id).isEmpty {
            await embed(item)
        }
    }

    @discardableResult
    func embed(_ item: DownloadItem) async -> Bool {
        guard item.kind != .hls, item.status == .completed, !running.contains(item.id),
              let fileName = item.localFileName, let source = item.localURL,
              FileManager.default.fileExists(atPath: source.path) else { return false }
        let saved = SubtitleStore.saved(for: item.id)
        let tracks = saved.compactMap { file -> SubtitleRemuxer.Track? in
            let url = SubtitleStore.fileURL(of: file, for: item.id)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let cues = SubtitleParser.cues(from: text)
            return cues.isEmpty ? nil : SubtitleRemuxer.Track(language: file.language, name: file.label.isEmpty ? file.displayName : file.label, cues: cues)
        }
        guard !tracks.isEmpty else { return false }
        let size = DownloadStorage.allocatedSize(of: source) ?? 0
        if let free = DownloadStorage.availableCapacity(), free < size + 50_000_000 {
            record(item, "Not enough space to add subtitles to the video file; the app keeps drawing them")
            return false
        }
        running.insert(item.id)
        defer { running.remove(item.id) }

        let base = (fileName as NSString).deletingPathExtension
        let finalName = (fileName as NSString).pathExtension.lowercased() == "mov" ? base + "-subtitles.mov" : base + ".mov"
        let destination = DownloadStorage.storedURL(finalName)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await SubtitleRemuxer.remux(source, adding: tracks, defaultTrack: PlaybackCoordinator.defaultSiteIndex(saved), to: temporary)
            guard try await Self.verify(temporary, matches: source, subtitleTracks: tracks.count) else {
                record(item, "The video with subtitles didn't check out; the app keeps drawing them")
                return false
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            if destination != source { try? FileManager.default.removeItem(at: source) }
            item.localFileName = finalName
            item.fileSize = DownloadStorage.allocatedSize(of: destination)
            SubtitleStore.remove(for: item.id)
            ThumbnailCache.shared.evict(item.id)
            try? context.save()
            record(item, "Added \(tracks.count) site subtitle tracks to the video file: " + tracks.map(\.name).joined(separator: ", "))
            return true
        } catch {
            record(item, "Couldn't add subtitles to the video file (\(error)); the app keeps drawing them")
            return false
        }
    }

    /// Same length, and every subtitle language present.
    static func verify(_ output: URL, matches source: URL, subtitleTracks: Int) async throws -> Bool {
        let result = AVURLAsset(url: output)
        let original = AVURLAsset(url: source)
        let length = try await result.load(.duration).seconds
        let expected = try await original.load(.duration).seconds
        guard abs(length - expected) < 1 else { return false }
        let group = try await result.loadMediaSelectionGroup(for: .legible)
        let originalCount = (try await original.loadMediaSelectionGroup(for: .legible))?.options.count ?? 0
        return (group?.options.count ?? 0) >= originalCount + subtitleTracks
    }

    private func record(_ item: DownloadItem, _ note: String) {
        diagnostics?.record(event: "subtitles", url: item.remoteURL.absoluteString, note: note)
    }
}
