import Foundation

/// Pure URL/payload parsing shared by the WebKit bridge and SDK-free tests.
enum MediaDiscovery {
    static let messageName = "mediaDiscovery"
    /// Fragmented stream pieces are not standalone videos, even if a player
    /// momentarily exposes one as an element's currentSrc.
    static let segmentExtensions: Set<String> = ["ts", "m4s"]
    /// Audio-only files, such as a site's theme-song preview, aren't videos.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac"]

    static func candidate(from payload: Any, sourcePageURL: URL, frameURL: URL? = nil, isMainFrame: Bool = true) -> MediaCandidate? {
        guard let dictionary = payload as? [String: Any],
              let rawURL = dictionary["url"] as? String,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              !rawURL.lowercased().hasPrefix("blob:") else { return nil }

        let title = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentType = dictionary["contentType"] as? String
        let isMediaElement = dictionary["mediaElement"] as? Bool ?? false
        let kind = MediaKind(contentType: contentType)
            ?? MediaKind(rawValue: (dictionary["kind"] as? String) ?? "").flatMap { $0 == .unknown ? nil : $0 }
            ?? MediaKind(url: url)
        if segmentExtensions.contains(url.pathExtension.lowercased()) || audioExtensions.contains(url.pathExtension.lowercased()) { return nil }
        let mediaType = contentType?.lowercased() ?? ""
        if mediaType.hasPrefix("video/iso.segment") || mediaType.hasPrefix("video/mp2t") || mediaType.hasPrefix("audio/") { return nil }
        // Resource timing contains every image, script, and stylesheet.
        if !isMediaElement {
            guard kind != .unknown else { return nil }
        }
        let documentURL = (dictionary["documentURL"] as? String).flatMap(URL.init(string:))
        return MediaCandidate(url: url, sourcePageURL: sourcePageURL, frameURL: documentURL ?? frameURL, isMainFrame: isMainFrame,
                              title: title?.isEmpty == false ? title! : "Discovered video",
                              kind: kind, quality: dictionary["quality"] as? String, contentType: contentType)
    }

    static func normalizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    static func isDuplicate(_ candidate: MediaCandidate, in candidates: [MediaCandidate]) -> Bool {
        let normalized = normalizedURL(candidate.url)
        return candidates.contains { normalizedURL($0.url) == normalized }
    }

    /// A main-frame message is stale when it was sent by a document other than the one now shown
    /// (e.g. a late message from the previous episode). Sub-frame players are judged by navigation clearing.
    static func isStale(documentURL: URL?, isMainFrame: Bool, currentPageURL: URL) -> Bool {
        guard isMainFrame, let documentURL else { return false }
        return normalizedURL(documentURL) != normalizedURL(currentPageURL)
    }
}
