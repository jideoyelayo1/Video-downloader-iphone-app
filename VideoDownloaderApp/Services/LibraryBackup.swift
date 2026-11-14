import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Library records only, not the video files; restoring merges by ID.
struct LibraryBackup: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var createdAt = Date()
    var videos: [Video] = []
    var labels: [Label] = []
    var shows: [ShowRecord] = []
    var folders: [Folder] = []

    struct Video: Codable {
        var id: UUID, title: String, remoteURL: URL, sourcePageURL: URL, refererURL: URL?, kind: String
        var localFileName: String?, createdAt: Date, completedAt: Date?, fileSize: Int64?, playbackPosition: Double?
        var folderID: UUID?, watchedAt: Date?, lastPlayedAt: Date?, duration: Double?, labelIDs: [UUID]?
        var showID: UUID?, showOrder: Int?, posterURL: URL?, requiresReferer: Bool?, isMovie: Bool?
    }
    struct Label: Codable { var id: UUID, name: String, colorName: String, sites: [String]?, isSiteLabel: Bool? }
    struct ShowRecord: Codable {
        var id: UUID, title: String, autoplayNext: Bool, introStart: Double?, introEnd: Double?, creditsFromEnd: Double?
        var autoSkipIntro: Bool, playbackRate: Double?, followSourceURL: URL?, notifyNewEpisodes: Bool, autoDownloadNewEpisodes: Bool
    }
    struct Folder: Codable { var id: UUID, title: String }

    enum RestoreError: LocalizedError {
        case newerVersion
        case couldNotSave(Error)

        var errorDescription: String? {
            switch self {
            case .newerVersion: "This backup was made by a newer version of Video Downloader. Update the app, then restore it."
            case .couldNotSave(let error): "The library couldn't be saved, so nothing was restored: \(error.localizedDescription)"
            }
        }
    }

    struct Summary: Equatable {
        var added = 0, updated = 0, missingFiles = 0
        var text: String {
            var parts = ["\(added) added", "\(updated) updated"]
            if missingFiles > 0 { parts.append("\(missingFiles) to download again (under Needs Attention in Downloads)") }
            return parts.joined(separator: ", ") + "."
        }
    }

    @MainActor
    static func make(from context: ModelContext) -> LibraryBackup {
        var backup = LibraryBackup()
        let items = (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []
        // Skips only active downloads, so videos a restore left to download again are kept.
        backup.videos = items.filter { !$0.isActive }.map {
            Video(id: $0.id, title: $0.title, remoteURL: $0.remoteURL, sourcePageURL: $0.sourcePageURL, refererURL: $0.refererURL, kind: $0.kindRaw,
                  localFileName: $0.localFileName, createdAt: $0.createdAt, completedAt: $0.completedAt, fileSize: $0.fileSize,
                  playbackPosition: $0.playbackPosition, folderID: $0.folderID, watchedAt: $0.watchedAt, lastPlayedAt: $0.lastPlayedAt,
                  duration: $0.duration, labelIDs: $0.labelIDs, showID: $0.showID, showOrder: $0.showOrder, posterURL: $0.posterURL,
                  requiresReferer: $0.requiresRefererRaw, isMovie: $0.isMovie)
        }
        backup.labels = ((try? context.fetch(FetchDescriptor<VideoLabel>())) ?? []).map {
            Label(id: $0.id, name: $0.name, colorName: $0.colorName, sites: $0.sites, isSiteLabel: $0.isSiteLabel)
        }
        backup.shows = ((try? context.fetch(FetchDescriptor<Show>())) ?? []).map {
            ShowRecord(id: $0.id, title: $0.title, autoplayNext: $0.autoplayNext, introStart: $0.introStart, introEnd: $0.introEnd,
                       creditsFromEnd: $0.creditsFromEnd, autoSkipIntro: $0.autoSkipIntro, playbackRate: $0.playbackRate,
                       followSourceURL: $0.followSourceURL, notifyNewEpisodes: $0.notifyNewEpisodes, autoDownloadNewEpisodes: $0.autoDownloadNewEpisodes)
        }
        backup.folders = ((try? context.fetch(FetchDescriptor<DownloadFolder>())) ?? []).map { Folder(id: $0.id, title: $0.title) }
        return backup
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> LibraryBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LibraryBackup.self, from: data)
        // A newer backup may hold records this version would misread or drop.
        guard backup.version <= currentVersion else { throw RestoreError.newerVersion }
        return backup
    }

    @MainActor
    func restore(into context: ModelContext) throws -> Summary {
        var summary = Summary()
        let folders = Dictionary(((try? context.fetch(FetchDescriptor<DownloadFolder>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for folder in self.folders where folders[folder.id] == nil { context.insert(DownloadFolder(id: folder.id, title: folder.title)) }
        let labels = Dictionary(((try? context.fetch(FetchDescriptor<VideoLabel>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for label in self.labels where labels[label.id] == nil {
            context.insert(VideoLabel(id: label.id, name: label.name, colorName: label.colorName, sites: label.sites ?? [], isSiteLabel: label.isSiteLabel ?? false))
        }
        let shows = Dictionary(((try? context.fetch(FetchDescriptor<Show>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for record in self.shows {
            let show = shows[record.id] ?? {
                let show = Show(id: record.id, title: record.title)
                context.insert(show)
                return show
            }()
            show.autoplayNext = record.autoplayNext
            show.introStart = record.introStart
            show.introEnd = record.introEnd
            show.creditsFromEnd = record.creditsFromEnd
            show.autoSkipIntro = record.autoSkipIntro
            show.playbackRate = record.playbackRate
            show.followSourceURL = record.followSourceURL
            show.notifyNewEpisodes = record.notifyNewEpisodes
            show.autoDownloadNewEpisodes = record.autoDownloadNewEpisodes
        }
        let items = Dictionary(((try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for video in videos {
            let item: DownloadItem
            if let existing = items[video.id] {
                item = existing
                summary.updated += 1
            } else {
                item = DownloadItem(id: video.id, title: video.title, remoteURL: video.remoteURL, sourcePageURL: video.sourcePageURL,
                                    refererURL: video.refererURL, kind: MediaKind(rawValue: video.kind) ?? .unknown, status: .completed,
                                    createdAt: video.createdAt, requiresReferer: video.requiresReferer ?? false)
                item.localFileName = video.localFileName
                item.completedAt = video.completedAt
                item.fileSize = video.fileSize
                item.progress = 1
                context.insert(item)
                summary.added += 1
            }
            // A video downloading right now keeps its transfer; only its library details change.
            let downloading = item.isActive
            item.folderID = video.folderID
            item.watchedAt = video.watchedAt
            item.lastPlayedAt = video.lastPlayedAt
            item.duration = video.duration ?? item.duration
            // Older backups have no labels or movie flag; nil there keeps what's on this iPhone.
            item.labelIDs = video.labelIDs ?? item.labelIDs
            item.showID = video.showID
            item.showOrder = video.showOrder
            item.isMovieRaw = video.isMovie ?? item.isMovieRaw
            item.playbackPosition = video.playbackPosition
            item.posterURL = video.posterURL ?? item.posterURL
            if !downloading, !(item.localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                item.status = .failed
                item.errorMessage = "Restored from a backup. The video file isn't on this iPhone: tap Open Page to download it again."
                summary.missingFiles += 1
            }
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw RestoreError.couldNotSave(error)
        }
        return summary
    }
}

/// The backup as a file to share or save, made only when shared.
struct LibraryBackupFile: Transferable {
    let make: @MainActor @Sendable () -> LibraryBackup

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let backup = await MainActor.run { file.make() }
            let name = "Video Downloader Library \(backup.createdAt.formatted(.iso8601.year().month().day())).json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try backup.encoded().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
