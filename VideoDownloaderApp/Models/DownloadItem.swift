import Foundation
import SwiftData

enum DownloadStorage {
    static let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    static let containerRoot = applicationSupportDirectory.deletingLastPathComponent()
    static let libraryDirectory: URL = {
        var directory = applicationSupportDirectory.appendingPathComponent("VideoDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Videos can be downloaded again, so they stay out of backups; the library store doesn't.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
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

    static let subtitlesDirectory: URL = {
        let directory = applicationSupportDirectory.appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    static func storedURL(_ path: String) -> URL {
        if path.hasPrefix("@managed/") { return containerRoot.appendingPathComponent(String(path.dropFirst("@managed/".count))) }
        // Older HLS packages saved absolute paths, into the container of the install that saved them.
        if path.hasPrefix("/") { return pathInContainer(path).map { containerRoot.appendingPathComponent($0) } ?? URL(fileURLWithPath: path) }
        return libraryDirectory.appendingPathComponent(path)
    }

    /// Container paths change between installs, so system-managed HLS packages are stored relative to it.
    static func managedPath(for location: URL) -> String {
        pathInContainer(location.path).map { "@managed/" + $0 } ?? location.path
    }

    /// Path below `containerRoot`, from any install's container; iOS 27 reports HLS paths under /.nofollow.
    static func pathInContainer(_ path: String) -> String? {
        guard let inside = afterContainer(path), let rootInside = afterContainer(containerRoot.path) else {
            let root = containerRoot.path.hasSuffix("/") ? containerRoot.path : containerRoot.path + "/"
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
        }
        let prefix = rootInside.hasSuffix("/") ? rootInside : rootInside + "/"
        return inside.hasPrefix(prefix) ? String(inside.dropFirst(prefix.count)) : nil
    }

    private static func afterContainer(_ path: String) -> Substring? {
        guard let marker = path.range(of: "/Containers/Data/Application/") else { return nil }
        let rest = path[marker.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return rest[rest.index(after: slash)...]
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

enum LibrarySchema {
    static let models: [any PersistentModel.Type] = [DownloadItem.self, Bookmark.self, DownloadFolder.self, BrowsingHistoryEntry.self,
                                                     VideoLabel.self, Show.self]

    static func container(inMemory: Bool) throws -> ModelContainer {
        try ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    /// Moves a store that won't open into Library Recovery, so the next launch starts afresh.
    static func setAsideSavedStore() throws -> URL {
        let store = ModelConfiguration().url
        let folder = DownloadStorage.applicationSupportDirectory
            .appendingPathComponent("Library Recovery/\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: store.path + suffix) {
            try FileManager.default.moveItem(atPath: store.path + suffix, toPath: folder.appendingPathComponent(store.lastPathComponent + suffix).path)
        }
        return folder
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
    var playbackPosition: Double?
    /// Kept as an ID so deleting a folder never deletes media.
    var folderID: UUID?
    /// Minimum HLS variant bitrate chosen by the user, if any.
    var preferredBitrate: Int?
    /// Relay HLS requests through the app when the host requires a Referer.
    var requiresRefererRaw: Bool?
    var watchedAt: Date?
    var lastPlayedAt: Date?
    var duration: Double?
    /// Kept as IDs so deleting a label never deletes media.
    var labelIDs: [UUID]?
    var showID: UUID?
    var showOrder: Int?
    var posterURL: URL?
    var isMovieRaw: Bool?

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

    var isWatched: Bool { watchedAt != nil }

    var isMovie: Bool {
        get { isMovieRaw == true }
        set { isMovieRaw = newValue }
    }

    /// Downloads saved before `completedAt` was recorded fall back to when they were added.
    var downloadedText: String {
        if let completedAt { return "Downloaded \(Self.dateTimeFormatter.string(from: completedAt))" }
        return "Added \(Self.dateTimeFormatter.string(from: createdAt))"
    }

    var completedTimeText: String? { completedAt.map(Self.dateTimeFormatter.string(from:)) }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter
    }()
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

/// Labels with `sites` are added automatically to downloads from those sites.
@Model
final class VideoLabel {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorName: String
    /// Hosts such as "***REMOVED***.to"; subdomains match too.
    var sites: [String]?
    var isSiteLabel: Bool?
    var createdAt: Date

    init(id: UUID = UUID(), name: String, colorName: String = "blue", sites: [String] = [], isSiteLabel: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.sites = sites
        self.isSiteLabel = isSiteLabel
        self.createdAt = createdAt
    }
}

@Model
final class Show {
    @Attribute(.unique) var id: UUID
    var title: String
    var autoplayNextRaw: Bool?
    var createdAt: Date
    var introStart: Double?
    var introEnd: Double?
    /// Where the credits start, in seconds before the end, so it fits episodes of any length.
    var creditsFromEnd: Double?
    var autoSkipIntroRaw: Bool?
    var playbackRate: Double?
    /// The page of the latest episode, for checking whether the next one is out.
    var followSourceURL: URL?
    var notifyNewEpisodesRaw: Bool?
    var autoDownloadNewEpisodesRaw: Bool?
    var lastCheckedAt: Date?
    var lastCheckNeededVerification: Bool?
    /// Latest play of a deleted watched episode, so Continue Watching still offers the one after it.
    var deletedEpisodePlayedAt: Date?

    init(id: UUID = UUID(), title: String, autoplayNext: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.autoplayNextRaw = autoplayNext
        self.createdAt = createdAt
    }

    var autoplayNext: Bool {
        get { autoplayNextRaw ?? true }
        set { autoplayNextRaw = newValue }
    }

    var autoSkipIntro: Bool {
        get { autoSkipIntroRaw ?? false }
        set { autoSkipIntroRaw = newValue }
    }

    var notifyNewEpisodes: Bool {
        get { notifyNewEpisodesRaw ?? false }
        set { notifyNewEpisodesRaw = newValue }
    }

    var autoDownloadNewEpisodes: Bool {
        get { autoDownloadNewEpisodesRaw ?? false }
        set { autoDownloadNewEpisodesRaw = newValue }
    }

    var hasIntroOrCredits: Bool { introStart != nil || introEnd != nil || creditsFromEnd != nil }
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
        ("***REMOVED***", URL(string: "https://***REMOVED***tv.to/home")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.to/home")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.to/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.to/anime")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.ws/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.live/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.com/")!)
    ]

    static let testedSites: [(String, URL)] = [
        ("***REMOVED***", URL(string: "https://www.***REMOVED***.to/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.to/anime")!),
        ("My***REMOVED***", URL(string: "https://my***REMOVED***.lol/home/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.one/home")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.ru/home")!),
        ("***REMOVED***", URL(string: "https://www.***REMOVED***.com/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.com.lv/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***tv.to/home")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.ws/")!)
    ] + addedTestedSites + laterTestedSites

    /// Added once to libraries that already had the earlier tested sites.
    static let addedTestedSites: [(String, URL)] = [
        ("***REMOVED***", URL(string: "https://***REMOVED***.onl/home")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.day/")!)
    ]

    /// Added once to existing libraries, like `addedTestedSites`.
    static let laterTestedSites: [(String, URL)] = [
        ("***REMOVED***", URL(string: "https://***REMOVED***.su/")!),
        ("***REMOVED***", URL(string: "https://***REMOVED***.org/")!),
        ("***REMOVED***", URL(string: "https://ww1.***REMOVED***.to/")!),
        ("***REMOVED***s", URL(string: "https://***REMOVED***s.ru/")!)
    ]

    static var knownSites: [(String, URL)] { starters + testedSites }

    /// Groups in the bookmarks list; case order is the order shown.
    enum Folder: String, CaseIterable {
        case autoDownload = "Auto-Download", downloadOnly = "Download Only", needsTap = "Needs a Tap",
             browseOnly = "Browse Only", mine = "My Sites"

        var footer: String {
            switch self {
            case .autoDownload: "Episode pages are numbered: follow a show here to download each new episode automatically."
            case .downloadOnly: "Videos save, but episode pages aren't numbered, so the next episode can't be found automatically."
            case .needsTap: "Tap the site's own play button before the video can be found, so automatic downloads can't run."
            case .browseOnly: "Lists of sites, or players whose streams can't be saved (DASH or scrambled)."
            case .mine: ""
            }
        }
    }

    /// Keyed by the shipped site names above.
    private static let siteFolders: [String: Folder] = [
        "***REMOVED***": .autoDownload, "***REMOVED***": .autoDownload, "My***REMOVED***": .autoDownload, "***REMOVED***": .autoDownload,
        "***REMOVED***": .autoDownload, "***REMOVED***": .autoDownload,
        "***REMOVED***": .downloadOnly, "***REMOVED***s": .downloadOnly, "***REMOVED***": .downloadOnly, "***REMOVED***": .downloadOnly,
        "***REMOVED***": .downloadOnly, "***REMOVED***": .downloadOnly, "***REMOVED***": .downloadOnly,
        "***REMOVED***": .needsTap, "***REMOVED***": .needsTap,
        "***REMOVED***": .browseOnly, "***REMOVED***": .browseOnly, "***REMOVED***": .browseOnly
    ]

    var folder: Folder { url.host.flatMap { Self.siteFolders[SiteNames.name(for: $0)] } ?? .mine }

    static let oldStarterURLs: Set<String> = [
        "https://my***REMOVED***.lol/watch/tv/95350-free-lanterns-hd/season-1/episode-1/",
        "https://www.***REMOVED***.tv/watch/178789/mushoku-tensei-iii-isekai-ittara-honki-dasu?ep=13"
    ]
}

@Model
final class BrowsingHistoryEntry {
    @Attribute(.unique) var id: UUID
    var title: String
    var url: URL
    var visitedAt: Date

    init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
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
        // Keep the file for the next launch unless its videos are safely in the store.
        do { try context.save() } catch { context.rollback(); return 0 }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported"))
        return items.count
    }
}
