import AVFoundation
import UIKit

/// Thumbnails and durations for Library rows.
///
/// A row can appear twice (Continue Watching and All Videos) and reappears while
/// scrolling, and the HLS fallback decodes video with a playing `AVPlayer`. So each
/// video gets one extraction in flight, failures are remembered for the session,
/// extractions run one at a time, and file reads and image decoding stay off the main thread.
@MainActor
final class ThumbnailCache {
    typealias Generator = (_ mediaURL: URL, _ kind: MediaKind) async -> Data?

    static let shared = ThumbnailCache()

    private final class Entry {
        let fileName: String?
        let image: UIImage
        init(fileName: String?, image: UIImage) { self.fileName = fileName; self.image = image }
    }

    private let images = NSCache<NSUUID, Entry>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failed: Set<String> = []
    private var durations: [String: Double] = [:]
    private let generator: Generator
    private let thumbnailURL: (UUID) -> URL
    private var extracting = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(generator: @escaping Generator = { url, kind in await VideoThumbnailService.imageData(for: url, kind: kind) },
         thumbnailURL: @escaping (UUID) -> URL = DownloadStorage.thumbnailURL(for:)) {
        self.generator = generator
        self.thumbnailURL = thumbnailURL
        images.countLimit = 200
    }

    /// A decoded image already in memory, so a reappearing row needs no placeholder.
    func cachedImage(for id: UUID, fileName: String?) -> UIImage? {
        guard let entry = images.object(forKey: id as NSUUID), entry.fileName == fileName else { return nil }
        return entry.image
    }

    func image(for id: UUID, fileName: String?, mediaURL: URL?, kind: MediaKind) async -> UIImage? {
        if let image = cachedImage(for: id, fileName: fileName) { return image }
        let key = Self.key(id, fileName)
        if failed.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }
        // Unstructured on purpose: a row scrolling away must not cancel work another row is awaiting.
        let task = Task { await self.load(id: id, mediaURL: mediaURL, kind: kind) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { images.setObject(Entry(fileName: fileName, image: image), forKey: id as NSUUID) } else { failed.insert(key) }
        return image
    }

    func duration(of url: URL, fileName: String) async -> Double? {
        if let cached = durations[fileName] { return cached }
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0 else { return nil }
        durations[fileName] = seconds
        return seconds
    }

    func evict(_ id: UUID) {
        images.removeObject(forKey: id as NSUUID)
        failed = failed.filter { !$0.hasPrefix(id.uuidString) }
    }

    private func load(id: UUID, mediaURL: URL?, kind: MediaKind) async -> UIImage? {
        let file = thumbnailURL(id)
        if let image = await Self.decode(contentsOf: file) { return image }
        guard let mediaURL else { return nil }
        await acquire()
        let data = await generator(mediaURL, kind)
        release()
        guard let data else { return nil }
        return await Task.detached(priority: .utility) {
            try? data.write(to: file, options: .atomic)
            return await Self.prepared(data)
        }.value
    }

    nonisolated private static func decode(contentsOf file: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return await prepared(data)
        }.value
    }

    /// Decodes now, off the main thread, instead of on first draw during scrolling.
    nonisolated private static func prepared(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }

    private static func key(_ id: UUID, _ fileName: String?) -> String { "\(id.uuidString)|\(fileName ?? "")" }

    private func acquire() async {
        guard extracting else { extracting = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { extracting = false } else { waiting.removeFirst().resume() }
    }
}
