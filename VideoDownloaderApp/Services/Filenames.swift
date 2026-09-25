import Foundation

enum Filenames {
    static let maxTitleLength = 120
    /// Keeps the full name comfortably under the 255-byte APFS limit even for multi-scalar graphemes.
    static let maxTitleBytes = 180

    private static let forbidden = Set("/\\:?%*|\"<>")
    private static let bidiControls = Set<Unicode.Scalar>((0x202A...0x202E).compactMap(Unicode.Scalar.init) + (0x2066...0x2069).compactMap(Unicode.Scalar.init))
    private static let knownExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "ts", "m2ts", "avi", "3gp", "flv", "ogv", "mpg", "mpeg", "wmv", "m4a", "mp3", "aac"]
    private static let mimeExtensions: [String: String] = [
        "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm", "video/x-matroska": "mkv",
        "video/mp2t": "ts", "video/x-m4v": "m4v", "video/3gpp": "3gp", "video/mpeg": "mpg", "video/ogg": "ogv",
        "video/x-msvideo": "avi", "video/x-flv": "flv", "audio/mp4": "m4a", "audio/mpeg": "mp3",
    ]

    static func safe(title: String, extension ext: String, id: UUID) -> String {
        var cleaned = ""
        for character in title {
            if forbidden.contains(character) { continue }
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || bidiControls.contains($0) }) {
                cleaned.append(" ")
                continue
            }
            cleaned.append(character.isWhitespace ? " " : character)
        }
        var name = trim(cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        name = String(name.prefix(maxTitleLength))
        while name.utf8.count > maxTitleBytes { name.removeLast() }
        name = trim(name)
        if name.isEmpty { name = "video" }
        return "\(name)-\(id.uuidString).\(validExtension(ext) ?? "mp4")"
    }

    static func fileExtension(suggestedFilename: String?, url: URL?, mimeType: String?) -> String {
        if let name = suggestedFilename, let ext = knownExtension((name as NSString).pathExtension) { return ext }
        if let url, let ext = knownExtension(url.pathExtension) { return ext }
        if let mime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           let ext = mimeExtensions[mime] { return ext }
        return "mp4"
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    private static func validExtension(_ ext: String) -> String? {
        let lower = ext.lowercased()
        guard (1...5).contains(lower.count), lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return lower
    }

    private static func knownExtension(_ ext: String) -> String? {
        validExtension(ext).flatMap { knownExtensions.contains($0) ? $0 : nil }
    }
}
