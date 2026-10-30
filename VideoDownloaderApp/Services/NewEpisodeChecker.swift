import BackgroundTasks
import Foundation
import UserNotifications

/// Checks whether the next episode of a followed show is out: it looks for a video on the page
/// after the show's latest episode, the way "Download Next Episodes" does. It then notifies, or
/// downloads the episode, as the show is set to. Runs when the app becomes active and in iOS's
/// background refresh, which iOS schedules as it sees fit.
@MainActor
final class NewEpisodeChecker {
    static let backgroundTaskID = "com.jideoyelayo.VideoDownloader.newEpisodes"
    private static let notifiedKey = "notifiedEpisodePages"

    private let shows: ShowStore
    private let downloads: DownloadManager
    private let preferences: UserDefaults
    private let find: (URL) async -> SeasonDownloader.PageResult
    /// Downloads a found episode (`SeasonDownloader.download`).
    private let download: (SeasonDownloader.PageResult) -> DownloadItem?
    private let notify: (String, String) async -> Void
    var diagnostics: DiagnosticsLog?
    /// A show isn't checked again sooner than this, unless asked.
    var interval: TimeInterval = 6 * 3600
    private var checking = false

    init(shows: ShowStore, downloads: DownloadManager, preferences: UserDefaults,
         find: @escaping (URL) async -> SeasonDownloader.PageResult,
         download: @escaping (SeasonDownloader.PageResult) -> DownloadItem?,
         notify: @escaping (String, String) async -> Void = NewEpisodeChecker.postNotification) {
        self.shows = shows
        self.downloads = downloads
        self.preferences = preferences
        self.find = find
        self.download = download
        self.notify = notify
    }

    /// Checks the followed shows that are due; returns how many new episodes were found.
    @discardableResult
    func checkFollowedShows(force: Bool = false, now: Date = Date()) async -> Int {
        guard !checking else { return 0 }
        checking = true
        defer { checking = false }
        var found = 0
        let followed = shows.shows.filter { $0.notifyNewEpisodes || $0.autoDownloadNewEpisodes }
        // Longest unchecked first, in case iOS ends a background refresh part-way.
        for show in followed.sorted(by: { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }) {
            if !force, let last = show.lastCheckedAt, now.timeIntervalSince(last) < interval { continue }
            // A show with several episodes out catches up, a few at a time.
            for _ in 0..<3 {
                let following = show.followSourceURL
                guard await check(show, now: now) else { break }
                found += 1
                guard show.followSourceURL != following else { break }
            }
        }
        return found
    }

    @discardableResult
    func check(_ show: Show, now: Date = Date()) async -> Bool {
        guard let latest = show.followSourceURL, let next = EpisodeURL.next(after: latest) else { return false }
        // Already downloaded (from Browse, say): follow on from it without announcing it.
        if let saved = downloads.savedOrActiveEpisode(atPage: next) {
            if saved.showID != show.id { shows.add([saved], to: show) } else { show.followSourceURL = next; shows.save() }
            return false
        }
        let result = await find(next)
        // A background refresh that iOS cut short didn't really look: check again next time.
        guard !Task.isCancelled else { return false }
        show.lastCheckedAt = now
        show.lastCheckNeededVerification = result == .verification ? true : nil
        shows.save()
        guard case .found = result else {
            let outcome = result == .verification ? "the site wants verification in Browse" : "not out yet"
            diagnostics?.record(event: "new-episode", url: next.absoluteString, note: "\(show.title): \(outcome)")
            return false
        }
        var notified = Set(preferences.stringArray(forKey: Self.notifiedKey) ?? [])
        let episode = EpisodeURL.number(in: next).map { "Episode \($0)" } ?? "The next episode"
        // Nil when the download was refused, for example for lack of storage.
        let item = show.autoDownloadNewEpisodes ? download(result) : nil
        if let item, item.showID != show.id { shows.add([item], to: show) }
        if !notified.contains(next.absoluteString) {
            notified.insert(next.absoluteString)
            preferences.set(Array(notified), forKey: Self.notifiedKey)
            await notify("\(episode) of \(show.title) is out", Self.notificationBody(autoDownload: show.autoDownloadNewEpisodes, started: item != nil))
        }
        diagnostics?.record(event: "new-episode", url: next.absoluteString, note: "\(show.title): found")
        return true
    }

    static func notificationBody(autoDownload: Bool, started: Bool) -> String {
        if started { return "It's downloading now." }
        return autoDownload ? "It couldn't download automatically. Open the show's page in Browse to download it."
                            : "Open the show's page in Browse to download it."
    }

    static func postNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Background refresh

    /// Registered once, before the app finishes launching.
    static func registerBackgroundTask(_ handler: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            let work = Task { @MainActor in
                await handler()
                scheduleBackgroundCheck()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundCheck() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
