import Foundation

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleParser {
    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ("&lrm;", ""), ("&rlm;", ""), ("&amp;", "&")
    ]

    /// Drops styling tags, cue identifiers, NOTE/STYLE/REGION blocks and cue settings; skips empty cues.
    static func cues(from text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        // Blocks are separated by blank lines, which may contain stray spaces.
        var blocks: [[String]] = [[]]
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        var cues: [SubtitleCue] = []
        for lines in blocks {
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let end = timestamp(String(endToken)), end > start else { continue }
            let body = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func text(at time: Double, in cues: [SubtitleCue]) -> String? {
        let showing = cues.lazy.prefix { $0.start <= time }.filter { time < $0.end }.map(\.text)
        let text = showing.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// `hh:mm:ss.ttt`, `mm:ss.ttt`, or SRT's comma form.
    static func timestamp(_ raw: String) -> Double? {
        let fields = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    private static func clean(_ line: String) -> String {
        var text = tagPattern.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
