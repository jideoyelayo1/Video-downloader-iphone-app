import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playback: PlaybackCoordinator
    @StateObject private var browser = BrowserViewModel(diagnostics: AppServices.shared.diagnostics, history: AppServices.shared.history)
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
        // A page's video would otherwise keep playing, and streaming, behind other tabs and saved videos.
        .onChange(of: selection) { previous, _ in
            guard previous == .browse else { return }
            browser.pauseMedia()
            // The address field keeps first responder in the hidden tab otherwise.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: playback.isPresented) { _, presented in if presented { browser.pauseMedia() } }
        .alert("Unable to play video", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.clearError() } })) {
            Button("OK", role: .cancel) { playback.clearError() }
        } message: { Text(playback.errorMessage ?? "") }
        .alert("Can't start download", isPresented: Binding(get: { downloads.startError != nil }, set: { if !$0 { downloads.startError = nil } })) {
            Button("OK", role: .cancel) { downloads.startError = nil }
        } message: { Text(downloads.startError ?? "") }
    }
}
