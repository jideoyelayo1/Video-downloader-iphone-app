import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playback: PlaybackCoordinator
    @StateObject private var browser = BrowserViewModel(diagnostics: AppServices.shared.diagnostics, history: AppServices.shared.history)
    /// A page given with `-StartURL` (tests and site checks) opens in Browse.
    @State private var selection = LaunchOptions.value("-StartURL") != nil ? Tab.browse : Tab.library
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: playback.isPresented) { _, presented in
            if presented { browser.pauseMedia() }
            updateBrowserVisibility()
        }
        .onChange(of: selection) { updateBrowserVisibility() }
        .onChange(of: scenePhase) { _, phase in
            updateBrowserVisibility()
            if phase == .active, !LaunchOptions.isRunningUnitTests {
                Task { await AppServices.shared.newEpisodes.checkFollowedShows() }
            }
            if phase == .background { NewEpisodeChecker.scheduleBackgroundCheck() }
        }
        .onAppear { updateBrowserVisibility() }
        .alert("Unable to play video", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.clearError() } })) {
            Button("OK", role: .cancel) { playback.clearError() }
        } message: { Text(playback.errorMessage ?? "") }
        // Delete Finished Episodes → Ask First, for an episode closed in its last 10%. It waits
        // while another video plays.
        .confirmationDialog("Delete this episode?",
                            isPresented: Binding(get: { playback.finishedEpisode != nil && !playback.isPresented },
                                                 set: { if !$0 { playback.answerFinishedEpisode(delete: false) } }),
                            titleVisibility: .visible, presenting: playback.finishedEpisode) { _ in
            Button("Delete Episode", role: .destructive) { playback.answerFinishedEpisode(delete: true) }
            Button("Keep", role: .cancel) { playback.answerFinishedEpisode(delete: false) }
        } message: { episode in Text("You finished \(episode.displayTitle). \(StorageCleanup.freedText(episode))") }
        .alert("Can't start download", isPresented: Binding(get: { downloads.startError != nil }, set: { if !$0 { downloads.startError = nil } })) {
            Button("OK", role: .cancel) { downloads.startError = nil }
        } message: { Text(downloads.startError ?? "") }
    }

    private func updateBrowserVisibility() {
        browser.isVisible = selection == .browse && scenePhase == .active && !playback.isPresented
    }
}
