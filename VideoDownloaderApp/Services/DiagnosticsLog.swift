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

        var line: String {
            let time = ISO8601DateFormatter().string(from: date)
            return "\(time) [\(event)] \(isMainFrame ? "main" : "frame") \(url)"
                + (contentType.map { " type=\($0)" } ?? "")
                + (note.map { " — \($0)" } ?? "")
                + (frameURL.map { " (frame: \($0))" } ?? "")
        }
    }

    static let maxEntries = 3000
    @Published private(set) var entries: [Entry] = []
    /// Mirror of the log inside the app container, readable with `xcrun simctl get_app_container`.
    let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostics.log")

    func record(event: String, url: String, frameURL: URL? = nil, isMainFrame: Bool = true, contentType: String? = nil, note: String? = nil) {
        let entry = Entry(date: Date(), event: event, url: url, frameURL: isMainFrame ? nil : frameURL?.absoluteString,
                          isMainFrame: isMainFrame, contentType: contentType, note: note)
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        append(entry.line + "\n")
    }

    func clear() {
        entries.removeAll()
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
}
