import Foundation

/// Subtitle files saved beside a download, with the labels the site's player gave them.
/// Saved when the download starts, because the files' URLs expire like the stream's.
enum SubtitleStore {
    struct Saved: Codable, Equatable {
        let fileName: String
        let label: String
        let language: String?
        let isDefault: Bool

        var displayName: String { SubtitleTrack.displayName(label: label, language: language) }
    }

    static let maxBytes = 2_000_000
    static let maxTracks = 24
    private static let manifestName = "tracks.json"

    static func directory(for id: UUID, in root: URL = DownloadStorage.subtitlesDirectory) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func saved(for id: UUID, in root: URL = DownloadStorage.subtitlesDirectory) -> [Saved] {
        guard let data = try? Data(contentsOf: directory(for: id, in: root).appendingPathComponent(manifestName)) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: data)) ?? []
    }

    static func fileURL(of saved: Saved, for id: UUID, in root: URL = DownloadStorage.subtitlesDirectory) -> URL {
        directory(for: id, in: root).appendingPathComponent(saved.fileName)
    }

    static func remove(for id: UUID, in root: URL = DownloadStorage.subtitlesDirectory) {
        try? FileManager.default.removeItem(at: directory(for: id, in: root))
    }

    /// Fetches the tracks and replaces any saved earlier for this item. Files that aren't
    /// readable WebVTT or SRT (an error page, an expired link) are skipped.
    @discardableResult
    static func save(_ tracks: [SubtitleTrack], for id: UUID, in root: URL = DownloadStorage.subtitlesDirectory,
                     session: URLSession = SubtitleStore.session,
                     context: (SubtitleTrack) async -> RequestContext?) async -> [Saved] {
        var saved: [Saved] = []
        var files: [(name: String, text: String)] = []
        for track in tracks.prefix(maxTracks) {
            var request = URLRequest(url: track.url)
            let requestContext = await context(track)
            requestContext?.apply(to: &request)
            guard let (data, response) = try? await session.data(for: request, delegate: RedirectScoper(context: requestContext, original: request)),
                  let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
                  data.count <= maxBytes,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !SubtitleParser.cues(from: text).isEmpty else { continue }
            let name = "\(files.count).vtt"
            files.append((name, text))
            saved.append(Saved(fileName: name, label: track.label, language: track.language, isDefault: track.isDefault))
        }
        let directory = directory(for: id, in: root)
        try? FileManager.default.removeItem(at: directory)
        guard !saved.isEmpty else { return [] }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in files { try file.text.write(to: directory.appendingPathComponent(file.name), atomically: true, encoding: .utf8) }
            try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return []
        }
        return saved
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
}
