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
            var language = (entry["language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if language?.isEmpty != false { language = label.isEmpty ? languageCode(in: url) : languageCode(named: label) }
            return SubtitleTrack(url: url, label: label, language: language,
                                 isDefault: entry["isDefault"] as? Bool ?? false, referer: documentURL)
        }
    }

    /// A file found by its download has no label; its name often is the language: `eng.vtt`,
    /// `en.srt`, `English.vtt`, `?lang=fr`.
    static func languageCode(in url: URL) -> String? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { ["lang", "language"].contains($0.name.lowercased()) }?.value
        let stem = url.deletingPathExtension().lastPathComponent
        // "<id>.en.srt", "show_eng.vtt"
        let suffix = stem.split(whereSeparator: { ".-_".contains($0) }).last.map(String.init)
        return [query, stem, suffix].lazy.compactMap { $0.flatMap(languageCode(named:)) }.first
    }

    /// "en", "eng" or "English" → "en". Only two-letter languages: three-letter codes like
    /// "sub" are rare languages, not captions.
    static func languageCode(named raw: String) -> String? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let english = Locale(identifier: "en")
        return Locale.LanguageCode.isoLanguageCodes.first {
            $0.identifier.count == 2 && ($0.identifier == name || $0.identifier(.alpha3) == name
                || english.localizedString(forLanguageCode: $0.identifier)?.lowercased() == name)
        }?.identifier
    }
}
