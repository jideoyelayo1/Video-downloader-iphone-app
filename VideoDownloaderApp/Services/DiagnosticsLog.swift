import Foundation

/// Raw record of what pages and player frames load, for diagnosing site compatibility.
@MainActor
final class DiagnosticsLog: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let event: String
        let url: String
        let frameURL: String?
        let isMainFrame: Bool
        let contentType: String?
        let note: String?
        var previousLine: String? = nil

        var line: String {
            if let previousLine { return previousLine }
            let time = ISO8601DateFormatter().string(from: date)
            return "\(time) [\(event)] \(isMainFrame ? "main" : "frame") \(url)"
                + (contentType.map { " type=\($0)" } ?? "")
                + (note.map { " — \($0)" } ?? "")
                + (frameURL.map { " (frame: \($0))" } ?? "")
        }
    }

    static let maxEntries = 1000
    @Published private(set) var entries: [Entry] = []
    private var entriesSinceCompaction = 0
    /// Mirror of the log inside the app container, readable with `xcrun simctl get_app_container`.
    let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostics.log")) {
        self.fileURL = fileURL
        // Older builds wrote complete URLs, including possible signed query strings.
        if fileURL.lastPathComponent == "diagnostics.log" && !UserDefaults.standard.bool(forKey: "diagnosticsSafeFormatV1") {
            try? FileManager.default.removeItem(at: fileURL)
            UserDefaults.standard.set(true, forKey: "diagnosticsSafeFormatV1")
        }
        if let stored = try? String(contentsOf: fileURL, encoding: .utf8) {
            entries = stored.split(separator: "\n").suffix(Self.maxEntries).map {
                Entry(date: .distantPast, event: "Previous session", url: "", frameURL: nil,
                      isMainFrame: true, contentType: nil, note: nil, previousLine: String($0))
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        record(event: "session", url: "app://launch", note: "version=\(version) iOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func record(event: String, url: String, frameURL: URL? = nil, isMainFrame: Bool = true, contentType: String? = nil, note: String? = nil) {
        let entry = Entry(date: Date(), event: event, url: Self.safeURL(url), frameURL: isMainFrame ? nil : frameURL.map { Self.safeURL($0.absoluteString) },
                          isMainFrame: isMainFrame, contentType: contentType, note: note.map(Self.redactURLs))
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            entriesSinceCompaction += 1
        }
        // Compaction is a full-file write. Batch it so a burst of browser
        // events cannot rewrite the entire log once per event.
        if entriesSinceCompaction >= 100 {
            persist()
            entriesSinceCompaction = 0
        } else {
            append(entry.line + "\n")
        }
    }

    func clear() {
        entries.removeAll()
        entriesSinceCompaction = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    var text: String { entries.map(\.line).joined(separator: "\n") }

    /// Writes the log to a shareable temporary file.
    func exportFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoDownloader-diagnostics.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func persist() {
        try? (text + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func safeURL(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw), parts.scheme != nil else { return raw }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? raw
    }

    private static func redactURLs(_ note: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"https?://[^\s)]+"#)
        var result = note
        for match in pattern.matches(in: note, range: NSRange(note.startIndex..., in: note)).reversed() {
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: safeURL(String(result[range])))
            }
        }
        return result
    }
}
