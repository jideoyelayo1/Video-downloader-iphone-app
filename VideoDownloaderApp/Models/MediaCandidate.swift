import Foundation

enum MediaKind: String, Codable, CaseIterable {
    case video
    case hls
    case unknown

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "m3u8": self = .hls
        case "mp4", "m4v", "mov", "webm", "mkv", "ts": self = .video
        default: self = .unknown
        }
    }

    init?(contentType: String?) {
        let type = contentType?.lowercased() ?? ""
        if type.contains("mpegurl") { self = .hls }
        else if type.hasPrefix("video/") && !type.hasPrefix("video/mp2t") && !type.hasPrefix("video/iso.segment") { self = .video }
        else { return nil }
    }

    var label: String {
        switch self {
        case .hls: return "HLS stream"
        case .video: return "Video file"
        case .unknown: return "Media"
        }
    }
}

struct MediaCandidate: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    /// The top-level page the user was viewing.
    let sourcePageURL: URL
    /// The document (often a cross-origin player iframe) that referenced the media; used as Referer.
    let frameURL: URL?
    let isMainFrame: Bool
    var title: String
    var kind: MediaKind
    var quality: String?
    var contentType: String?
    let discoveredAt: Date

    init(url: URL, sourcePageURL: URL, frameURL: URL? = nil, isMainFrame: Bool = true, title: String = "Discovered video",
         kind: MediaKind? = nil, quality: String? = nil, contentType: String? = nil) {
        self.id = UUID()
        self.url = url
        self.sourcePageURL = sourcePageURL
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
        self.title = title
        self.kind = kind ?? MediaKind(contentType: contentType) ?? MediaKind(url: url)
        self.quality = quality
        self.contentType = contentType
        self.discoveredAt = Date()
    }

    var referer: URL { frameURL ?? sourcePageURL }
}
