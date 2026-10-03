import Foundation

struct HLSVariant: Equatable {
    let url: URL
    let bandwidth: Int?
    let resolution: String?

    var qualityLabel: String {
        if let resolution, let height = resolution.lowercased().split(separator: "x").last.flatMap({ Int($0) }), height > 0 {
            return "\(height)p"
        }
        if let bandwidth, bandwidth > 0 { return "\(bandwidth / 1000) kbps" }
        return "Auto"
    }

    /// Roughly how much this quality takes for a stream of the given length (peak bandwidth, so an upper estimate).
    func estimatedBytes(duration: Double?) -> Int64? {
        guard let bandwidth, bandwidth > 0, let duration, duration.isFinite, duration > 0 else { return nil }
        return Int64(Double(bandwidth) / 8 * duration)
    }

    /// "720p · about 351 MB".
    func menuTitle(duration: Double?) -> String {
        guard let bytes = estimatedBytes(duration: duration) else { return qualityLabel }
        return qualityLabel + " · about " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum HLSManifest: Equatable {
    case master(variants: [HLSVariant])
    case media(isFinite: Bool, isEncryptedWithDRM: Bool, segmentCount: Int, totalDuration: Double)

    static func parse(_ text: String, baseURL: URL) -> HLSManifest? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard trimmed.hasPrefix("#EXTM3U") else { return nil }
        let lines = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            var variants: [HLSVariant] = []
            var pending: [String: String]?
            for line in lines where !line.isEmpty {
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    pending = attributes(of: line)
                } else if !line.hasPrefix("#"), let attrs = pending {
                    pending = nil
                    guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                    variants.append(HLSVariant(url: url, bandwidth: attrs["BANDWIDTH"].flatMap { Int($0) }, resolution: attrs["RESOLUTION"]))
                }
            }
            let sorted = variants.enumerated().sorted { a, b in
                let (x, y) = (a.element.bandwidth ?? -1, b.element.bandwidth ?? -1)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
            return .master(variants: sorted)
        }

        var isFinite = false, isDRM = false, segments = 0, duration = 0.0
        for line in lines {
            if line.hasPrefix("#EXT-X-ENDLIST") {
                isFinite = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                if line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count).trimmingCharacters(in: .whitespaces).uppercased() == "VOD" { isFinite = true }
            } else if line.hasPrefix("#EXTINF:") {
                segments += 1
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                duration += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                if isDRMKey(attributes(of: line)) { isDRM = true }
            }
        }
        return .media(isFinite: isFinite, isEncryptedWithDRM: isDRM, segmentCount: segments, totalDuration: duration)
    }

    /// Playlists a master references besides its variants: separate audio, subtitle and
    /// I-frame renditions. A player fetches them alongside the master, but none is a
    /// complete video on its own.
    static func renditionURLs(in text: String, baseURL: URL) -> [URL] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:"),
                  let uri = attributes(of: line)["URI"], !uri.isEmpty else { return nil }
            return URL(string: uri, relativeTo: baseURL)?.absoluteURL
        }
    }

    private static func isDRMKey(_ attrs: [String: String]) -> Bool {
        let method = attrs["METHOD"]?.uppercased() ?? ""
        if method == "SAMPLE-AES" || method == "SAMPLE-AES-CTR" { return true }
        if attrs["URI"]?.lowercased().hasPrefix("skd://") == true { return true }
        return attrs["KEYFORMAT"]?.lowercased() == "com.apple.streamingkeydelivery"
    }

    /// Parses `#TAG:KEY=VALUE,KEY="quoted, value"` into a dictionary with unquoted values and uppercased keys.
    static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty { result[k] = value.trimmingCharacters(in: .whitespaces) }
            key = ""; value = ""; inKey = true
        }
        for ch in line[line.index(after: colon)...] {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }
}
