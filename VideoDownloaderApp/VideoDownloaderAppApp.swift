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
        }
        .modelContainer(services.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // The app may be launched in the background just for this, before any scene exists.
        AppServices.shared.downloads.setBackgroundCompletionHandler(completionHandler, for: identifier)
    }
}

/// Long-lived services, created once per process.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let downloads: DownloadManager
    let diagnostics = DiagnosticsLog()
    let playback: PlaybackCoordinator
    let history: BrowserHistoryStore
    let labels: LabelStore
    /// App settings; a fresh, separate store when UI tests run with an in-memory library.
    let preferences: UserDefaults

    private init() {
        let inMemory = LaunchOptions.isRunningUnitTests || LaunchOptions.flag("-UITestInMemory")
        do {
            container = try LibrarySchema.container(inMemory: inMemory)
        } catch {
            fatalError("Unable to open the download library: \(error)")
        }
        let context = container.mainContext
        if !inMemory { LegacyDownloadImport.run(into: context) }
        StarterBookmarks.install(in: context, inMemory: inMemory)
        history = BrowserHistoryStore(context: context)
        // Created once: an isolated test suite is cleared each time it is requested.
        preferences = LaunchOptions.preferences(isolated: inMemory)
        labels = LabelStore(context: context, preferences: preferences)
        labels.backfillSiteLabelsIfNeeded()
        downloads = DownloadManager(context: context, restore: !LaunchOptions.isRunningUnitTests)
        downloads.labelStore = labels
        playback = PlaybackCoordinator(context: context, diagnostics: diagnostics, preferences: preferences)
        downloads.requestContextProvider = { url, referer in await BrowserSession.requestContext(for: url, referer: referer) }
        downloads.diagnostics = diagnostics
    }
}

/// Process launch arguments used by tests and the site-compatibility runs.
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

    static var diagnosticsEnabled: Bool {
        #if DEBUG
        return flag("-VerboseBrowserDiagnostics")
        #else
        return false
        #endif
    }
}
