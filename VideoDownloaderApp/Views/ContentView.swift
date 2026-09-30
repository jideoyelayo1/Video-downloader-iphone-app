import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playback: PlaybackCoordinator
    @StateObject private var browser = BrowserViewModel(diagnostics: AppServices.shared.diagnostics)
    @State private var selection = Tab.library

    enum Tab { case browse, downloads, library }

    var body: some View {
        TabView(selection: $selection) {
            LibraryScreen(showBrowse: { selection = .browse })
                .tabItem { Label("My Videos", systemImage: "play.rectangle.on.rectangle") }
                .tag(Tab.library)
            BrowserScreen(model: browser, showDownloads: { selection = .downloads })
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(Tab.browse)
            DownloadsScreen(openSource: { url in browser.navigate(to: url.absoluteString); selection = .browse })
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $playback.isPresented) {
            PersistentPlayerScreen()
                .environmentObject(playback)
        }
        .alert("Can't start download", isPresented: Binding(get: { downloads.startError != nil }, set: { if !$0 { downloads.startError = nil } })) {
            Button("OK", role: .cancel) { downloads.startError = nil }
        } message: { Text(downloads.startError ?? "") }
    }
}
