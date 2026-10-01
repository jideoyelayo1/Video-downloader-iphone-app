import AVFoundation
import Combine
import Foundation
import SwiftData

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    typealias ContextProvider = @MainActor (_ mediaURL: URL, _ referer: URL?) async -> RequestContext?

    static let sessionPrefix = Bundle.main.bundleIdentifier ?? "VideoDownloaderApp"
    static let directSessionID = sessionPrefix + ".downloads"
    static let hlsSessionID = sessionPrefix + ".hls"

    /// Progress is kept in memory and only persisted occasionally, so ticks don't hit the store.
    let progressStore = DownloadProgressStore()
    /// A start that was refused before any item was created (e.g. insufficient storage).
    @Published var startError: String?

    let context: ModelContext
    var requestContextProvider: ContextProvider?
    var diagnostics: DiagnosticsLog?
    private let directConfiguration: URLSessionConfiguration
    private var directTasks: [UUID: URLSessionDownloadTask] = [:]
    private var hlsTasks: [UUID: AVAssetDownloadTask] = [:]
    private var hlsProxies: [UUID: HLSRefererProxy] = [:]
    private var hlsLocations: [UUID: URL] = [:]
    private var injectedCookies: [UUID: [HTTPCookie]] = [:]
    private var userCancelled: Set<UUID> = []
    /// Identity of the most recent start attempt for each item. A context lookup can
    /// suspend after `begin` marks an item downloading; this token prevents that old
    /// lookup from starting a task after the user cancels and retries the item.
    private var attemptIDs: [UUID: UUID] = [:]
    /// The attempt whose cancellation is allowed to persist resume data. A late
    /// callback from an older cancellation must not overwrite a newer retry's data.
    private var cancelledAttempts: [UUID: UUID] = [:]
    /// Context lookups that have marked an item downloading but have not created a
    /// URLSession task yet. Relaunch reconciliation must not call these attempts
    /// orphaned while their browser lookup is still suspended.
    private var pendingBegins: [UUID: UUID] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private var lastProgressSave: [UUID: Date] = [:]
    private var progressSamples: [UUID: (date: Date, progress: Double)] = [:]

    private lazy var session = URLSession(configuration: directConfiguration, delegate: self, delegateQueue: .main)
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }()
    private var cookieStorage: HTTPCookieStorage { directConfiguration.httpCookieStorage ?? .shared }

    /// - Parameter directConfiguration: defaults to a background session; tests pass a foreground one.
    init(context: ModelContext, directConfiguration: URLSessionConfiguration? = nil, restore: Bool = true) {
        self.context = context
        self.directConfiguration = directConfiguration ?? {
            let configuration = URLSessionConfiguration.background(withIdentifier: DownloadManager.directSessionID)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            return configuration
        }()
        super.init()
        if restore { Task { await restoreTasks() } }
    }

    // MARK: Queue actions

    @discardableResult
    func start(_ candidate: MediaCandidate, expectedBytes: Int64? = nil, preferredBitrate: Int? = nil,
               requiresReferer: Bool = false) -> DownloadItem? {
        if MediaDiscovery.segmentExtensions.contains(candidate.url.pathExtension.lowercased()) {
            startError = DownloadError.streamSegment.message
            return nil
        }
        if let existing = items(for: candidate.url).first(where: \.isActive) { return existing }
        if let error = DownloadError.storageCheck(expectedBytes: expectedBytes, availableBytes: DownloadStorage.availableCapacity()) {
            startError = error.message
            return nil
        }
        // A fresh tap on the same source should repair its existing row rather than
        // create another identical failure in Downloads.
        let prior = (try? context.fetch(FetchDescriptor<DownloadItem>()))?.first {
            ($0.status == .failed || $0.status == .cancelled) &&
            ($0.remoteURL == candidate.url || ($0.sourcePageURL == candidate.sourcePageURL && $0.title == candidate.title))
        }
        if let existing = prior {
            existing.remoteURL = candidate.url
            existing.sourcePageURL = candidate.sourcePageURL
            existing.refererURL = candidate.referer
            existing.kind = candidate.kind
            existing.preferredBitrate = preferredBitrate
            existing.requiresReferer = requiresReferer
            restart(existing)
            return existing
        }
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = DownloadItem(title: title.isEmpty ? "Video" : title, remoteURL: candidate.url, sourcePageURL: candidate.sourcePageURL,
                                refererURL: candidate.referer, kind: candidate.kind, preferredBitrate: preferredBitrate,
                                requiresReferer: requiresReferer)
        context.insert(item)
        begin(item)
        return item
    }

    func cancel(_ item: DownloadItem) {
        guard item.isActive else { return }
        let cancelledAttemptID = attemptIDs[item.id]
        attemptIDs[item.id] = nil
        if let cancelledAttemptID { cancelledAttempts[item.id] = cancelledAttemptID }
        userCancelled.insert(item.id)
        item.status = .cancelled
        progressStore.setEstimate(item.id, nil)
        progressSamples[item.id] = nil
        save()
        let resumeURL = item.resumeDataURL
        let id = item.id
        directTasks.removeValue(forKey: id)?.cancel(byProducingResumeData: { [weak self] data in
            guard let data, let cancelledAttemptID else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.cancelledAttempts[id] == cancelledAttemptID,
                      let item = self.item(id), item.status == .cancelled,
                      item.modelContext != nil else { return }
                try? data.write(to: resumeURL)
            }
        })
        hlsTasks.removeValue(forKey: item.id)?.cancel()
        hlsProxies.removeValue(forKey: item.id)?.stop()
    }

    func retry(_ item: DownloadItem) {
        guard !item.isActive else { return }
        userCancelled.remove(item.id)
        begin(item)
    }

    func restart(_ item: DownloadItem) {
        guard !item.isActive else { return }
        try? FileManager.default.removeItem(at: item.resumeDataURL)
        if let localURL = item.localURL { try? FileManager.default.removeItem(at: localURL) }
        item.localFileName = nil
        item.progress = 0
        userCancelled.remove(item.id)
        begin(item)
    }

    func delete(_ item: DownloadItem) {
        attemptIDs[item.id] = nil
        cancelledAttempts[item.id] = nil
        userCancelled.insert(item.id)
        directTasks.removeValue(forKey: item.id)?.cancel()
        hlsTasks.removeValue(forKey: item.id)?.cancel()
        hlsProxies.removeValue(forKey: item.id)?.stop()
        if let location = hlsLocations.removeValue(forKey: item.id) ?? item.localURL { try? FileManager.default.removeItem(at: location) }
        try? FileManager.default.removeItem(at: item.resumeDataURL)
        try? FileManager.default.removeItem(at: DownloadStorage.thumbnailURL(for: item.id))
        ThumbnailCache.shared.evict(item.id)
        releaseCookies(for: item.id)
        clearProgress(for: item.id)
        context.delete(item)
        save()
    }

    func rename(_ item: DownloadItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        item.title = trimmed
        save()
    }

    func progress(of item: DownloadItem) -> Double { progressStore.fraction(of: item.id) ?? item.progress }
    func estimatedSeconds(of item: DownloadItem) -> TimeInterval? { progressStore.estimatedSeconds[item.id] }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletionHandlers[identifier] = handler
        // Touch the matching session so it reconnects and delivers its pending events.
        if identifier == Self.hlsSessionID { _ = hlsSession } else { _ = session }
    }

    // MARK: Starting tasks

    /// Marks the item as downloading immediately, then creates the task once the browser context is gathered.
    private func begin(_ item: DownloadItem) {
        if item.kind == .hls || !FileManager.default.fileExists(atPath: item.resumeDataURL.path) { item.progress = 0 }
        let attemptID = UUID()
        attemptIDs[item.id] = attemptID
        cancelledAttempts[item.id] = nil
        pendingBegins[item.id] = attemptID
        item.status = .downloading
        item.errorMessage = nil
        diagnostics?.record(event: "download-start", url: item.remoteURL.absoluteString,
                            note: "kind=\(item.kind.rawValue) attempt=\(attemptID.uuidString)")
        progressStore.set(item.id, fraction: item.progress)
        progressStore.setEstimate(item.id, nil)
        progressSamples[item.id] = nil
        save()
        Task {
            let requestContext = await requestContextProvider?(item.remoteURL, item.refererURL)
            guard attemptIDs[item.id] == attemptID,
                  item.modelContext != nil,
                  item.status == .downloading,
                  !userCancelled.contains(item.id) else { return }
            if item.kind == .hls { await beginHLS(item, requestContext, attemptID: attemptID) } else { beginDirect(item, requestContext, attemptID: attemptID) }
            if pendingBegins[item.id] == attemptID { pendingBegins[item.id] = nil }
        }
    }

    private func beginDirect(_ item: DownloadItem, _ requestContext: RequestContext?, attemptID: UUID) {
        // Cookies go through the session's cookie storage rather than a header, so the URL loading
        // system scopes them per host on redirects (background sessions don't call the redirect delegate).
        let cookies = RequestContext.cookies(from: requestContext?.cookies ?? [], for: item.remoteURL)
        if !cookies.isEmpty {
            cookieStorage.setCookies(cookies, for: item.remoteURL, mainDocumentURL: item.remoteURL)
            injectedCookies[item.id] = cookies
        }
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: item.resumeDataURL) {
            try? FileManager.default.removeItem(at: item.resumeDataURL)
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: item.remoteURL)
            var headers = requestContext
            headers?.cookies = []
            headers?.apply(to: &request)
            task = session.downloadTask(with: request)
        }
        task.taskDescription = Self.taskDescription(itemID: item.id, attemptID: attemptID)
        directTasks[item.id] = task
        task.resume()
    }

    private func beginHLS(_ item: DownloadItem, _ requestContext: RequestContext?, attemptID: UUID) async {
        // Do not let a package path reported by an older task become the location
        // for this retry before AVFoundation reports the new task's package.
        hlsLocations[item.id] = nil
        var assetOptions: [String: Any] = [:]
        if let cookies = requestContext?.cookies, !cookies.isEmpty { assetOptions[AVURLAssetHTTPCookiesKey] = cookies }
        if let userAgent = requestContext?.userAgent { assetOptions[AVURLAssetHTTPUserAgentKey] = userAgent }
        let assetURL: URL
        if item.requiresReferer {
            guard let requestContext, requestContext.referer != nil else {
                fail(item, .other("The player context expired. Open the page, play the video, then download again."))
                return
            }
            do {
                let proxy = try HLSRefererProxy(context: requestContext)
                assetURL = try proxy.start(for: item.remoteURL)
                hlsProxies[item.id] = proxy
            } catch {
                fail(item, .other("Couldn't start the in-app stream relay. Try again while the app is open."))
                return
            }
            assetOptions.removeAll()
        } else {
            assetURL = item.remoteURL
        }
        let asset = AVURLAsset(url: assetURL, options: assetOptions)
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: item.title)
        if let bitrate = item.preferredBitrate {
            configuration.primaryContentConfiguration.variantQualifiers = [
                AVAssetVariantQualifier(predicate: NSPredicate(format: "averageBitRate >= %d", bitrate))
            ]
        }
        // Include the default audible rendition in every caption selection.
        let mediaSelections = await HLSMediaSelections.forDownload(asset: asset)
        if !mediaSelections.isEmpty { configuration.primaryContentConfiguration.mediaSelections = mediaSelections }
        if let captionGroup = try? await asset.loadMediaSelectionGroup(for: .legible) {
            diagnostics?.record(event: "captions", url: item.remoteURL.absoluteString,
                                note: "Advertised \(captionGroup.options.count) HLS tracks; requested \(mediaSelections.count) selections")
        }
        guard attemptIDs[item.id] == attemptID,
              item.modelContext != nil,
              item.status == .downloading,
              !userCancelled.contains(item.id) else { return }
        let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = Self.taskDescription(itemID: item.id, attemptID: attemptID)
        hlsTasks[item.id] = task
        task.resume()
    }

    // MARK: Completion

    private func finishDirect(_ task: URLSessionDownloadTask, location: URL) {
        guard let id = Self.itemID(task), let item = item(id), associate(task, item: item, id: id, isHLS: false) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        directTasks[id] = nil
        let response = task.response as? HTTPURLResponse
        if let failure = DownloadResponseValidation.failure(statusCode: response?.statusCode ?? 0, mimeType: response?.mimeType,
                                                           prefixData: Self.prefix(of: location)) {
            try? FileManager.default.removeItem(at: location)
            diagnostics?.record(event: "download", url: item.remoteURL.absoluteString,
                                note: "rejected HTTP \(response?.statusCode ?? 0) \(response?.mimeType ?? "no type"): \(failure.message)")
            fail(item, failure)
            return
        }
        let ext = Filenames.fileExtension(suggestedFilename: response?.suggestedFilename, url: response?.url ?? item.remoteURL, mimeType: response?.mimeType)
        let filename = Filenames.safe(title: item.title, extension: ext, id: item.id)
        let destination = DownloadStorage.libraryDirectory.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            item.localFileName = filename
            save()
            let attemptID = Self.attemptID(task)
            Task { [weak self] in
                guard let self else { return }
                let playable = (try? await AVURLAsset(url: destination).load(.isPlayable)) == true
                guard let current = self.item(id), current.status == .downloading,
                      current.localFileName == filename, self.attemptIDs[id] == attemptID else { return }
                if playable {
                    self.markCompleted(current, size: DownloadStorage.allocatedSize(of: destination))
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    current.localFileName = nil
                    self.diagnostics?.record(event: "download", url: current.remoteURL.absoluteString,
                                             note: "Downloaded file is not playable by AVFoundation")
                    self.fail(current, .other("This file downloaded, but iPhone cannot play its video format. Choose another source."))
                }
            }
        } catch {
            fail(item, DownloadError.from(error))
        }
    }

    private func complete(_ task: URLSessionTask, error: Error?) {
        guard let id = Self.itemID(task), let item = item(id) else { return }
        if item.isActive {
            guard associate(task, item: item, id: id, isHLS: task is AVAssetDownloadTask) else { return }
        } else {
            // A direct task can call didComplete(nil) after didFinishDownloadingTo
            // has already marked it complete. A cancelled task still gets a
            // cleanup callback, but only for the attempt that was cancelled.
            guard let taskAttemptID = Self.attemptID(task),
                  attemptIDs[id] == taskAttemptID || cancelledAttempts[id] == taskAttemptID else { return }
        }
        releaseCookies(for: id)
        let wasCancelled = userCancelled.remove(id) != nil || (error as? URLError)?.code == .cancelled

        if task is AVAssetDownloadTask {
            hlsTasks[id] = nil
            hlsProxies.removeValue(forKey: id)?.stop()
            let location = hlsLocations.removeValue(forKey: id) ?? item.localURL
            if let error {
                let nsError = error as NSError
                diagnostics?.record(event: "download", url: item.remoteURL.absoluteString, note: "HLS \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
                location.map { try? FileManager.default.removeItem(at: $0) }
                item.localFileName = nil
                if wasCancelled { item.status = .cancelled; save() } else { fail(item, DownloadError.from(error)) }
            } else if let location {
                item.localFileName = DownloadStorage.managedPath(for: location)
                save()
                let attemptID = Self.attemptID(task)
                Task { [weak self] in
                    guard let self else { return }
                    let savedAsset = AVURLAsset(url: location)
                    let playable = (try? await savedAsset.load(.isPlayable)) == true
                    let audioMissing = playable ? await HLSMediaSelections.isOfflineAudioMissing(in: savedAsset) : false
                    guard let current = self.item(id), current.status == .downloading,
                          current.localFileName == DownloadStorage.managedPath(for: location),
                          self.attemptIDs[id] == attemptID else { return }
                    if playable && !audioMissing {
                        if let group = try? await savedAsset.loadMediaSelectionGroup(for: .legible) {
                            let saved = savedAsset.assetCache?.mediaSelectionOptions(in: group).count ?? group.options.count
                            self.diagnostics?.record(event: "captions", url: current.remoteURL.absoluteString,
                                                     note: "Offline package has \(saved) of \(group.options.count) advertised tracks")
                        }
                        self.markCompleted(current, size: DownloadStorage.allocatedSize(of: location))
                    } else {
                        try? FileManager.default.removeItem(at: location)
                        current.localFileName = nil
                        self.diagnostics?.record(event: "download", url: current.remoteURL.absoluteString,
                                                 note: "Downloaded HLS package is not playable by AVFoundation")
                        self.fail(current, .other(audioMissing
                            ? "The stream saved without its audio track. Replay it in Browse and download again."
                            : "This stream downloaded, but iPhone cannot play the saved video. Choose another source."))
                    }
                }
            } else {
                fail(item, .other("The stream finished without saving any media."))
            }
            return
        }

        directTasks[id] = nil
        // Success is handled in didFinishDownloadingTo.
        guard let error else { return }
        let nsError = error as NSError
        diagnostics?.record(event: "download", url: item.remoteURL.absoluteString,
                            note: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription) \(nsError.userInfo[NSUnderlyingErrorKey].map { "underlying: \($0)" } ?? "")")
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: item.resumeDataURL)
        }
        if wasCancelled { item.status = .cancelled; save() } else { fail(item, DownloadError.from(error)) }
    }

    private func markCompleted(_ item: DownloadItem, size: Int64?) {
        item.status = .completed
        item.progress = 1
        item.fileSize = size
        item.completedAt = Date()
        item.errorMessage = nil
        clearProgress(for: item.id)
        try? FileManager.default.removeItem(at: item.resumeDataURL)
        save()
    }

    private func fail(_ item: DownloadItem, _ error: DownloadError) {
        diagnostics?.record(event: "download-error", url: item.remoteURL.absoluteString,
                            note: "\(error.message) item=\(item.id.uuidString)")
        item.status = error == .cancelled ? .cancelled : .failed
        item.errorMessage = error == .cancelled ? nil : error.message
        if let progress = progressStore.fraction(of: item.id) { item.progress = progress }
        clearProgress(for: item.id)
        save()
    }

    private func clearProgress(for id: UUID) {
        progressStore.remove(id)
        progressSamples[id] = nil
        lastProgressSave[id] = nil
    }

    private func updateProgress(_ id: UUID, _ value: Double) {
        let value = min(max(value, 0), 1)
        let now = Date()
        if let sample = progressSamples[id] {
            let elapsed = now.timeIntervalSince(sample.date)
            if elapsed >= 2, let estimate = DownloadTimeEstimate.seconds(elapsed: elapsed, from: sample.progress, to: value) {
                let previous = progressStore.estimatedSeconds[id]
                progressStore.setEstimate(id, previous.map { $0 * 0.7 + estimate * 0.3 } ?? estimate)
                progressSamples[id] = (now, value)
            }
        } else { progressSamples[id] = (now, value) }
        progressStore.set(id, fraction: value, now: now)
        if now.timeIntervalSince(lastProgressSave[id] ?? .distantPast) > 2, let item = item(id) {
            lastProgressSave[id] = now
            item.progress = value
            save()
        }
    }

    // MARK: Relaunch recovery

    func restoreTasks() async {
        for task in await session.allTasks {
            guard let id = Self.itemID(task), let item = item(id), let downloadTask = task as? URLSessionDownloadTask,
                  item.isActive, pendingBegins[id] == nil else { task.cancel(); continue }
            let attemptID = Self.attemptID(task) ?? UUID()
            if let currentAttempt = attemptIDs[id], currentAttempt != attemptID { task.cancel(); continue }
            downloadTask.taskDescription = Self.taskDescription(itemID: id, attemptID: attemptID)
            attemptIDs[id] = attemptID
            directTasks[id] = downloadTask
            item.status = .downloading
        }
        for task in await hlsSession.allTasks {
            guard let id = Self.itemID(task), let item = item(id), let assetTask = task as? AVAssetDownloadTask,
                  item.isActive, pendingBegins[id] == nil else { task.cancel(); continue }
            if item.requiresReferer {
                // The previous process's loopback relay no longer exists.
                task.cancel()
                continue
            }
            let attemptID = Self.attemptID(task) ?? UUID()
            if let currentAttempt = attemptIDs[id], currentAttempt != attemptID { task.cancel(); continue }
            assetTask.taskDescription = Self.taskDescription(itemID: id, attemptID: attemptID)
            attemptIDs[id] = attemptID
            hlsTasks[id] = assetTask
            if let location = item.localURL { hlsLocations[id] = location }
            item.status = .downloading
        }
        let active = (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []
        for item in active where item.isActive && pendingBegins[item.id] == nil && directTasks[item.id] == nil && hlsTasks[item.id] == nil {
            item.status = .failed
            item.errorMessage = FileManager.default.fileExists(atPath: item.resumeDataURL.path)
                ? "Download was interrupted. Tap Retry to resume."
                : "Download was interrupted. Tap Retry."
        }
        save()
    }

    // MARK: Helpers

    private func item(_ id: UUID) -> DownloadItem? {
        var descriptor = FetchDescriptor<DownloadItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func items(for url: URL) -> [DownloadItem] {
        (try? context.fetch(FetchDescriptor<DownloadItem>(predicate: #Predicate { $0.remoteURL == url }))) ?? []
    }

    private func save() {
        do { try context.save() } catch { startError = "Couldn't save the download list: \(error.localizedDescription)" }
    }

    /// Associates a delegate callback with its persisted item when the callback
    /// races startup restoration. Once a task is cancelled or superseded, its
    /// attempt token must match before it can be reattached.
    private func associate(_ task: URLSessionTask, item: DownloadItem, id: UUID, isHLS: Bool) -> Bool {
        guard item.isActive else { return false }
        let attemptID = Self.attemptID(task) ?? attemptIDs[id] ?? UUID()
        if let currentAttempt = attemptIDs[id], currentAttempt != attemptID { return false }
        if isHLS {
            guard let assetTask = task as? AVAssetDownloadTask else { return false }
            if let current = hlsTasks[id], current !== task { return false }
            hlsTasks[id] = assetTask
        } else {
            guard let downloadTask = task as? URLSessionDownloadTask else { return false }
            if let current = directTasks[id], current !== task { return false }
            directTasks[id] = downloadTask
        }
        attemptIDs[id] = attemptID
        task.taskDescription = Self.taskDescription(itemID: id, attemptID: attemptID)
        return true
    }

    /// Removes cookies this manager placed in the session's storage once no other in-flight task needs them.
    private func releaseCookies(for id: UUID) {
        guard let cookies = injectedCookies.removeValue(forKey: id) else { return }
        let stillNeeded = Set(injectedCookies.values.flatMap { $0 }.map { "\($0.domain)|\($0.path)|\($0.name)" })
        for cookie in cookies where !stillNeeded.contains("\(cookie.domain)|\(cookie.path)|\(cookie.name)") {
            cookieStorage.deleteCookie(cookie)
        }
    }

    nonisolated private static func taskDescription(itemID: UUID, attemptID: UUID) -> String {
        "\(itemID.uuidString)|\(attemptID.uuidString)"
    }

    nonisolated private static func itemID(_ task: URLSessionTask) -> UUID? {
        UUID(uuidString: task.taskDescription?.split(separator: "|", maxSplits: 1).first.map(String.init) ?? "")
    }

    nonisolated private static func attemptID(_ task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription,
              let suffix = description.split(separator: "|", maxSplits: 1).dropFirst().first else { return nil }
        return UUID(uuidString: String(suffix))
    }

    nonisolated private static func prefix(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 4096)
    }
}

enum DownloadTimeEstimate {
    static func seconds(elapsed: TimeInterval, from previous: Double, to current: Double) -> TimeInterval? {
        let delta = current - previous
        guard elapsed >= 2, delta > 0.001, current > 0, current < 1 else { return nil }
        return min((1 - current) * elapsed / delta, 7 * 24 * 3600)
    }
}

// Both sessions deliver delegate callbacks on the main queue.
extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so it must be handled synchronously.
        MainActor.assumeIsolated { finishDirect(downloadTask, location: location) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let id = Self.itemID(downloadTask) else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated {
            // A cancelled task can still deliver progress after a retry has
            // installed a new task for the same item. The registered task needs
            // no store lookup; this callback fires every few kilobytes.
            if directTasks[id] !== downloadTask {
                guard let item = self.item(id), associate(downloadTask, item: item, id: id, isHLS: false) else { return }
            }
            updateProgress(id, value)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { complete(task, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { backgroundCompletionHandlers.removeValue(forKey: session.configuration.identifier ?? "")?() }
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let id = Self.itemID(assetDownloadTask) else { return }
        MainActor.assumeIsolated {
            guard let item = self.item(id), associate(assetDownloadTask, item: item, id: id, isHLS: true) else { return }
            hlsLocations[id] = location
            // Persist early so a relaunch can find (and clean up) the package.
            item.localFileName = DownloadStorage.managedPath(for: location)
            save()
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        // Completion vs failure is decided in didCompleteWithError, which always follows.
        guard let id = Self.itemID(assetDownloadTask) else { return }
        MainActor.assumeIsolated {
            guard let item = self.item(id), associate(assetDownloadTask, item: item, id: id, isHLS: true) else { return }
            hlsLocations[id] = location
        }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                                totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let total = timeRangeExpectedToLoad.duration.seconds
        guard total > 0, let id = Self.itemID(assetDownloadTask) else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        MainActor.assumeIsolated {
            if hlsTasks[id] !== assetDownloadTask {
                guard let item = self.item(id), associate(assetDownloadTask, item: item, id: id, isHLS: true) else { return }
            }
            updateProgress(id, loaded / total)
        }
    }
}
