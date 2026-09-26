import Foundation
import SwiftData

enum DownloadStorage {
    static let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    static let containerRoot = applicationSupportDirectory.deletingLastPathComponent()
    static let libraryDirectory: URL = {
        let directory = applicationSupportDirectory.appendingPathComponent("VideoDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    static let resumeDataDirectory: URL = {
        let directory = applicationSupportDirectory.appendingPathComponent("ResumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    static let thumbnailDirectory: URL = {
        let directory = applicationSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    static func storedURL(_ path: String) -> URL {
        if path.hasPrefix("@managed/") { return containerRoot.appendingPathComponent(String(path.dropFirst("@managed/".count))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return libraryDirectory.appendingPathComponent(path)
    }

    /// The app container path changes between installs, so system-managed HLS packages are stored relative to it.
    static func managedPath(for location: URL) -> String {
        let root = containerRoot.path.hasSuffix("/") ? containerRoot.path : containerRoot.path + "/"
        if location.path.hasPrefix(root) { return "@managed/" + String(location.path.dropFirst(root.count)) }
        return location.path
    }

    static func availableCapacity() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func allocatedSize(of url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard isDirectory.boolValue else {
            let values = try? url.resourceValues(forKeys: keys)
            return Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
        }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled
}

@Model
final class DownloadItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var remoteURL: URL
    var sourcePageURL: URL
    /// Referer for re-requests; the player frame that referenced the media.
    var refererURL: URL?
    var kindRaw: String
    var statusRaw: String
    var localFileName: String?
    var progress: Double
    var errorMessage: String?
    var createdAt: Date
    var completedAt: Date?
    var fileSize: Int64?
    /// Last watched position in seconds; zero starts from the beginning.
    var playbackPosition: Double?
    /// Optional Library folder. Kept as an ID so deleting a folder never deletes media.
    var folderID: UUID?
    /// Minimum HLS variant bitrate chosen by the user, if any.
    var preferredBitrate: Int?
    /// Relay HLS requests through the app when the host requires a Referer.
    var requiresRefererRaw: Bool?

    init(id: UUID = UUID(), title: String, remoteURL: URL, sourcePageURL: URL, refererURL: URL? = nil, kind: MediaKind,
         status: DownloadStatus = .queued, createdAt: Date = Date(), preferredBitrate: Int? = nil, requiresReferer: Bool = false) {
        self.id = id
        self.title = title
        self.remoteURL = remoteURL
        self.sourcePageURL = sourcePageURL
        self.refererURL = refererURL
        self.kindRaw = kind.rawValue
        self.statusRaw = status.rawValue
        self.progress = 0
        self.createdAt = createdAt
        self.preferredBitrate = preferredBitrate
        self.requiresRefererRaw = requiresReferer
    }

    var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .unknown }
        set { kindRaw = newValue.rawValue }
    }

    var status: DownloadStatus {
        get { DownloadStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var localURL: URL? { localFileName.map(DownloadStorage.storedURL) }
    var resumeDataURL: URL { DownloadStorage.resumeDataDirectory.appendingPathComponent(id.uuidString) }
    var isActive: Bool { status == .queued || status == .downloading }
    var isStreamFragment: Bool { MediaDiscovery.segmentExtensions.contains(remoteURL.pathExtension.lowercased()) }
    var requiresReferer: Bool {
        get { requiresRefererRaw == true }
        set { requiresRefererRaw = newValue }
    }
}

@Model
final class DownloadFolder {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}

@Model
final class Bookmark {
    var title: String
    var url: URL
    var createdAt: Date

    init(title: String, url: URL, createdAt: Date = Date()) {
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }

    static let starters: [(String, URL)] = [
        ("My***REMOVED*** – Lanterns S1E1", URL(string: "https://my***REMOVED***.lol/watch/tv/95350-free-lanterns-hd/season-1/episode-1/")!),
        ("***REMOVED*** – Mushoku Tensei III E13", URL(string: "https://www.***REMOVED***.tv/watch/178789/mushoku-tensei-iii-isekai-ittara-honki-dasu?ep=13")!)
    ]
}

/// One-time migration of the pre-SwiftData `downloads.json` queue.
enum LegacyDownloadImport {
    private struct LegacyItem: Decodable {
        let id: UUID
        var title: String
        let remoteURL: URL
        let sourcePageURL: URL
        let kind: MediaKind
        var localFileName: String?
        var status: DownloadStatus
        var progress: Double
        var errorMessage: String?
        let createdAt: Date
        var completedAt: Date?
    }

    static var legacyURL: URL { DownloadStorage.libraryDirectory.appendingPathComponent("downloads.json") }

    @discardableResult
    static func run(into context: ModelContext, from url: URL = legacyURL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([LegacyItem].self, from: data) else { return 0 }
        for legacy in items {
            let item = DownloadItem(id: legacy.id, title: legacy.title, remoteURL: legacy.remoteURL, sourcePageURL: legacy.sourcePageURL,
                                    kind: legacy.kind, status: legacy.status, createdAt: legacy.createdAt)
            item.localFileName = legacy.localFileName
            item.progress = legacy.progress
            item.errorMessage = legacy.errorMessage
            item.completedAt = legacy.completedAt
            if item.isActive { item.status = .failed; item.errorMessage = "Download was interrupted. Tap Retry." }
            context.insert(item)
        }
        try? context.save()
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported"))
        return items.count
    }
}
