import Foundation

/// A subtitle file a page's player offers beside its video (an HTML `<track>`), such as
/// ***REMOVED***'s per-language WebVTT files. These aren't part of the stream, so they are
/// saved separately with a download.
struct SubtitleTrack: Codable, Hashable {
    let url: URL
    let label: String
    /// BCP 47 tag from the track's `srclang`, when given.
    let language: String?
    let isDefault: Bool
    /// The document that referenced the file; sent as Referer when saving it.
    let referer: URL?

    var displayName: String { Self.displayName(label: label, language: language) }

    static func displayName(label: String, language: String?) -> String {
        if !label.isEmpty { return label }
        if let language, let name = Locale.current.localizedString(forIdentifier: language) { return name }
        return language ?? "Subtitles"
    }

    /// Tidies labels such as ***REMOVED***'s "Portuguese (- Portuguese(Brazil))" to "Portuguese (Brazil)".
    static func cleanLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s*\(-\s*[^()]*\(([^()]*)\)\s*\)"#, with: " ($1)", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a discovery `subtitles` message: `{ tracks: [{ url, label, language, isDefault }], documentURL }`.
    static func tracks(from payload: [String: Any], frameURL: URL?) -> [SubtitleTrack] {
        guard let entries = payload["tracks"] as? [[String: Any]] else { return [] }
        let documentURL = (payload["documentURL"] as? String).flatMap(URL.init(string:)) ?? frameURL
        return entries.compactMap { entry in
            guard let raw = entry["url"] as? String, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let label = cleanLabel((entry["label"] as? String) ?? "")
            let language = (entry["language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SubtitleTrack(url: url, label: label, language: language?.isEmpty == false ? language : nil,
                                 isDefault: entry["isDefault"] as? Bool ?? false, referer: documentURL)
        }
    }
}
