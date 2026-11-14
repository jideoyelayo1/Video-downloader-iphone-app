import SwiftData
import SwiftUI
import UIKit

@main
struct VideoDownloaderAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(services.downloads)
                .environmentObject(services.downloads.progressStore)
                .environmentObject(services.diagnostics)
                .environmentObject(services.playback)
                .environmentObject(services.labels)
                .environmentObject(services.shows)
                .environmentObject(services.seasons)
        }
        .modelContainer(services.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // iOS requires background tasks to be registered before launch finishes.
        NewEpisodeChecker.registerBackgroundTask { await AppServices.shared.newEpisodes.checkFollowedShows() }
        // Unit tests run without Google Cast.
        if !LaunchOptions.isRunningUnitTests { CastController.setUp(AppServices.shared) }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Without the saved library, finished files would be discarded as unknown; iOS keeps the events.
        guard AppServices.shared.libraryOpenError == nil else { return completionHandler() }
        // The app may be launched in the background just for this, before any scene exists.
        AppServices.shared.downloads.setBackgroundCompletionHandler(completionHandler, for: identifier)
    }
}

@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let downloads: DownloadManager
    let diagnostics = DiagnosticsLog()
    let playback: PlaybackCoordinator
    let history: BrowserHistoryStore
    let labels: LabelStore
    let shows: ShowStore
    let subtitleEmbedder: SubtitleEmbedder
    let seasons: SeasonDownloader
    let newEpisodes: NewEpisodeChecker
    /// A fresh, separate store when UI tests run with an in-memory library.
    let preferences: UserDefaults
    /// Why the saved library didn't open; the app then runs in memory and leaves the saved one untouched.
    let libraryOpenError: Error?

    private init() {
        let recovering: Bool
        let inMemory = LaunchOptions.isRunningUnitTests || LaunchOptions.flag("-UITestInMemory")
        do {
            container = try LibrarySchema.container(inMemory: inMemory)
            libraryOpenError = nil
            recovering = false
        } catch {
            // A newer store or a launch before first unlock fails here too, so nothing is moved without asking.
            guard let fallback = try? LibrarySchema.container(inMemory: true) else { fatalError("Unable to open the download library: \(error)") }
            container = fallback
            libraryOpenError = error
            recovering = true
        }
        let context = container.mainContext
        // One-time imports and settings flags must wait for the saved library.
        let throwaway = inMemory || recovering
        if !throwaway { LegacyDownloadImport.run(into: context) }
        StarterBookmarks.install(in: context, inMemory: throwaway)
        history = BrowserHistoryStore(context: context)
        // Created once: an isolated test suite is cleared each time it is requested.
        preferences = LaunchOptions.preferences(isolated: throwaway)
        labels = LabelStore(context: context, preferences: preferences)
        labels.backfillSiteLabelsIfNeeded()
        shows = ShowStore(context: context, preferences: preferences)
        downloads = DownloadManager(context: context, restore: !LaunchOptions.isRunningUnitTests && !recovering)
        downloads.labelStore = labels
        downloads.preferences = preferences
        downloads.showStore = shows
        seasons = SeasonDownloader(downloads: downloads, shows: shows)
        seasons.diagnostics = diagnostics
        // The UI tests' episode videos are a few hundred KB.
        if inMemory { seasons.minimumEpisodeBytes = 0 }
        newEpisodes = NewEpisodeChecker(shows: shows, downloads: downloads, preferences: preferences,
                                        find: { [seasons] url in await seasons.findVideo(on: url) },
                                        download: { [seasons] result in seasons.download(result) })
        newEpisodes.diagnostics = diagnostics
        subtitleEmbedder = SubtitleEmbedder(context: context)
        subtitleEmbedder.diagnostics = diagnostics
        downloads.subtitleEmbedder = subtitleEmbedder
        playback = PlaybackCoordinator(context: context, diagnostics: diagnostics, preferences: preferences)
        playback.shows = shows
        playback.downloads = downloads
        downloads.requestContextProvider = { url, referer in await BrowserSession.requestContext(for: url, referer: referer) }
        downloads.diagnostics = diagnostics
        shows.fillMissingFollowedPages()
        if let libraryOpenError { diagnostics.record(event: "library", url: "app://library", note: "Couldn't open: \(libraryOpenError)") }
        if !LaunchOptions.isRunningUnitTests && !recovering {
            downloads.deleteOldWatchedVideos()
            Task { await subtitleEmbedder.embedPending() }
        }
    }
}

enum LaunchOptions {
    static var isRunningUnitTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    static func flag(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }

    static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `-StartURL <url>` opens a page at launch; `-NoInitialLoad` opens a blank browser.
    static var initialURL: URL? {
        if isRunningUnitTests || flag("-NoInitialLoad") { return nil }
        return value("-StartURL").flatMap(URL.init(string:)) ?? Bookmark.starters.first?.1
    }

    /// Debug-only: autoplay muted video in every frame so players reveal their stream URLs.
    static var autoplay: Bool {
        #if DEBUG
        return flag("-DiagnosticsAutoplay")
        #else
        return false
        #endif
    }

    /// Test runs keep viewer preferences (such as captions) out of the simulator's real defaults.
    static func preferences(isolated: Bool) -> UserDefaults {
        let suite = "VideoDownloaderApp.TestRun"
        guard isolated, let defaults = UserDefaults(suiteName: suite) else { return .standard }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Debug-only: `-UpNextSeconds <n>` lengthens the end card's countdown, for UI tests on a slow Mac.
    static var upNextSeconds: Int? {
        #if DEBUG
        return value("-UpNextSeconds").flatMap(Int.init)
        #else
        return nil
        #endif
    }

    static var diagnosticsEnabled: Bool {
        #if DEBUG
        return flag("-VerboseBrowserDiagnostics")
        #else
        return false
        #endif
    }
}
