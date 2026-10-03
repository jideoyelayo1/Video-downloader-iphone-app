import BackgroundTasks
import Foundation
import UserNotifications

/// Checks whether the next episode of a followed show is out: it looks for a video on the page
/// after the show's latest episode, the way "Download Next Episodes" does. It then notifies, or
/// downloads the episode, as the show is set to. Runs when the app becomes active and in iOS's
/// background refresh, which iOS schedules as it sees fit.
@MainActor
final class NewEpisodeChecker {
    static let backgroundTaskID = "com.jideoyelayo.VideoDownloaderApp.newEpisodes"
    private static let notifiedKey = "notifiedEpisodePages"

    private let shows: ShowStore
    private let downloads: DownloadManager
    private let preferences: UserDefaults
    private let find: (URL) async -> SeasonDownloader.PageResult
    private let notify: (String, String) async -> Void
    var diagnostics: DiagnosticsLog?
    /// A show isn't checked again sooner than this, unless asked.
    var interval: TimeInterval = 6 * 3600
    private var checking = false

    init(shows: ShowStore, downloads: DownloadManager, preferences: UserDefaults,
         find: @escaping (URL) async -> SeasonDownloader.PageResult,
         notify: @escaping (String, String) async -> Void = NewEpisodeChecker.postNotification) {
        self.shows = shows
        self.downloads = downloads
        self.preferences = preferences
        self.find = find
        self.notify = notify
    }

    /// Checks the followed shows that are due; returns how many new episodes were found.
    @discardableResult
    func checkFollowedShows(force: Bool = false, now: Date = Date()) async -> Int {
        guard !checking else { return 0 }
        checking = true
        defer { checking = false }
        var found = 0
        for show in shows.shows where show.notifyNewEpisodes || show.autoDownloadNewEpisodes {
            if !force, let last = show.lastCheckedAt, now.timeIntervalSince(last) < interval { continue }
            if await check(show, now: now) { found += 1 }
        }
        return found
    }

    @discardableResult
    func check(_ show: Show, now: Date = Date()) async -> Bool {
        guard let latest = show.followSourceURL, let next = EpisodeURL.next(after: latest) else { return false }
        show.lastCheckedAt = now
        shows.save()
        guard case .found(var candidate, let probe, let subtitles, let title, let poster) = await find(next) else {
            diagnostics?.record(event: "new-episode", url: next.absoluteString, note: "\(show.title): not out yet")
            return false
        }
        var notified = Set(preferences.stringArray(forKey: Self.notifiedKey) ?? [])
        let episode = EpisodeURL.number(in: next).map { "Episode \($0)" } ?? "The next episode"
        if show.autoDownloadNewEpisodes {
            candidate.kind = probe.kind
            if !title.isEmpty { candidate.title = title }
            if let item = downloads.start(candidate, expectedBytes: probe.expectedBytes, preferredBitrate: nil,
                                          requiresReferer: probe.requiresReferer, subtitles: subtitles, poster: poster), item.showID != show.id {
                shows.add([item], to: show)
            }
        }
        if !notified.contains(next.absoluteString) {
            notified.insert(next.absoluteString)
            preferences.set(Array(notified), forKey: Self.notifiedKey)
            await notify("\(episode) of \(show.title) is out",
                         show.autoDownloadNewEpisodes ? "It's downloading now." : "Open the show's page in Browse to download it.")
        }
        diagnostics?.record(event: "new-episode", url: next.absoluteString, note: "\(show.title): found")
        return true
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
