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
                .environmentObject(services.diagnostics)
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

    private init() {
        let inMemory = LaunchOptions.isRunningUnitTests || LaunchOptions.flag("-UITestInMemory")
        do {
            container = try ModelContainer(for: DownloadItem.self, Bookmark.self, DownloadFolder.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        } catch {
            fatalError("Unable to open the download library: \(error)")
        }
        let context = container.mainContext
        if !inMemory { LegacyDownloadImport.run(into: context) }
        if (try? context.fetchCount(FetchDescriptor<Bookmark>())) == 0, !UserDefaults.standard.bool(forKey: "seededBookmarks") || inMemory {
            for (title, url) in Bookmark.starters { context.insert(Bookmark(title: title, url: url)) }
            try? context.save()
            if !inMemory { UserDefaults.standard.set(true, forKey: "seededBookmarks") }
        }
        downloads = DownloadManager(context: context, restore: !LaunchOptions.isRunningUnitTests)
        downloads.requestContextProvider = { url, referer in await BrowserSession.requestContext(for: url, referer: referer) }
        if LaunchOptions.diagnosticsEnabled { downloads.diagnostics = diagnostics }
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

    static var diagnosticsEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
