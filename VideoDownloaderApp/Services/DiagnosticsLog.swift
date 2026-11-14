import CoreTransferable
import Foundation
import UniformTypeIdentifiers

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
        /// Built once when recorded, because verbose browsing can log many entries a second.
        let line: String
        /// Lines read back from an earlier launch keep only their text.
        let isPreviousSession: Bool

        init(date: Date, event: String, url: String, frameURL: String?, isMainFrame: Bool, contentType: String?, note: String?) {
            self.date = date
            self.event = event
            self.url = url
            self.frameURL = frameURL
            self.isMainFrame = isMainFrame
            self.contentType = contentType
            self.note = note
            line = "\(DiagnosticsLog.timestampFormatter.string(from: date)) [\(event)] \(isMainFrame ? "main" : "frame") \(url)"
                + (contentType.map { " type=\($0)" } ?? "")
                + (note.map { " — \($0)" } ?? "")
                + (frameURL.map { " (frame: \($0))" } ?? "")
            isPreviousSession = false
        }

        init(previousLine: String) {
            date = .distantPast
            event = "Previous session"
            url = ""
            frameURL = nil
            isMainFrame = true
            contentType = nil
            note = nil
            line = previousLine
            isPreviousSession = true
        }
    }

    static let maxEntries = 1000
    /// Read from entries made off the main actor too; ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s)]+"#)

    @Published private(set) var entries: [Entry] = []
    private var entriesSinceCompaction = 0
    private let writer: Writer
    /// Mirror of the log inside the app container, readable with `xcrun simctl get_app_container`.
    let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostics.log")) {
        self.fileURL = fileURL
        writer = Writer(fileURL: fileURL)
        // Another log may still be writing this file; read it only once those writes land.
        writer.flush()
        // Older builds wrote complete URLs, including possible signed query strings.
        if fileURL.lastPathComponent == "diagnostics.log" && !UserDefaults.standard.bool(forKey: "diagnosticsSafeFormatV1") {
            try? FileManager.default.removeItem(at: fileURL)
            UserDefaults.standard.set(true, forKey: "diagnosticsSafeFormatV1")
        }
        if let stored = try? String(contentsOf: fileURL, encoding: .utf8) {
            entries = stored.split(separator: "\n").suffix(Self.maxEntries).map { Entry(previousLine: String($0)) }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let expiry = BuildExpiry.date.map { " expires=" + $0.formatted(.iso8601) } ?? ""
        record(event: "session", url: "app://launch", note: "version=\(version) iOS=\(ProcessInfo.processInfo.operatingSystemVersionString)" + expiry)
    }

    func record(event: String, url: String, frameURL: URL? = nil, isMainFrame: Bool = true, contentType: String? = nil, note: String? = nil) {
        let entry = Entry(date: Date(), event: event, url: Self.safeURL(url), frameURL: isMainFrame ? nil : frameURL.map { Self.safeURL($0.absoluteString) },
                          isMainFrame: isMainFrame, contentType: contentType, note: note.map(Self.redactURLs))
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            entriesSinceCompaction += 1
        }
        // Compaction rewrites the whole file, so batch it rather than rewrite once per browser event.
        if entriesSinceCompaction >= 100 {
            writer.replace(with: text + "\n")
            entriesSinceCompaction = 0
        } else {
            writer.append(entry.line + "\n")
        }
    }

    func clear() {
        entries.removeAll()
        entriesSinceCompaction = 0
        writer.remove()
    }

    func flush() { writer.flush() }

    var text: String { entries.map(\.line).joined(separator: "\n") }

    func exportFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VideoDownloader-diagnostics.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
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
        var result = note
        for match in urlPattern.matches(in: note, range: NSRange(note.startIndex..., in: note)).reversed() {
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: safeURL(String(result[range])))
            }
        }
        return result
    }

    /// One queue for every log, so a new instance reading the same file sees what earlier ones wrote.
    private final class Writer: @unchecked Sendable {
        private static let queue = DispatchQueue(label: "DiagnosticsLog.writer", qos: .utility)
        private let fileURL: URL
        /// Only touched on `queue`.
        private var handle: FileHandle?

        init(fileURL: URL) { self.fileURL = fileURL }

        deinit { try? handle?.close() }

        func append(_ line: String) {
            Self.queue.async { [self] in
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                    }
                    handle = try? FileHandle(forWritingTo: fileURL)
                    _ = try? handle?.seekToEnd()
                }
                try? handle?.write(contentsOf: Data(line.utf8))
            }
        }

        func replace(with text: String) {
            Self.queue.async { [self] in
                closeHandle()
                try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }

        func remove() {
            Self.queue.sync {
                closeHandle()
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        func flush() { Self.queue.sync {} }

        private func closeHandle() {
            try? handle?.close()
            handle = nil
        }
    }
}

/// Shares the log as a text file, written only when the user actually shares it.
struct DiagnosticsExport: Transferable {
    let log: DiagnosticsLog

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(await export.log.exportFile())
        }
    }
}
