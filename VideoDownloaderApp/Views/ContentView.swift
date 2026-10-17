import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playback: PlaybackCoordinator
    @StateObject private var browser = BrowserViewModel(diagnostics: AppServices.shared.diagnostics, history: AppServices.shared.history)
    /// A page given with `-StartURL` (tests and site checks) opens in Browse.
    @State private var selection = LaunchOptions.value("-StartURL") != nil ? Tab.browse : Tab.library
    @Environment(\.scenePhase) private var scenePhase

    enum Tab { case browse, downloads, library, settings }

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
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(.brandRed)
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
        // Delete Finished Episodes → Ask First, for an episode closed in its last 10%: a banner over
        // the tab bar rather than a dialog. It waits while another video plays.
        .overlay(alignment: .bottom) {
            if let episode = playback.finishedEpisode, !playback.isPresented {
                FinishedEpisodeBanner(episode: episode) { playback.answerFinishedEpisode(delete: $0) }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: playback.finishedEpisode?.id)
        .alert("Can't start download", isPresented: Binding(get: { downloads.startError != nil }, set: { if !$0 { downloads.startError = nil } })) {
            Button("OK", role: .cancel) { downloads.startError = nil }
        } message: { Text(downloads.startError ?? "") }
    }

    private func updateBrowserVisibility() {
        browser.isVisible = selection == .browse && scenePhase == .active && !playback.isPresented
    }
}

extension Color {
    /// The app's accent: a deep red on black, as on Netflix.
    static let brandRed = Color(red: 0.898, green: 0.035, blue: 0.078)
}

/// "You finished … Delete it?" over the tab bar. Unanswered, it goes after a while and the episode is kept.
private struct FinishedEpisodeBanner: View {
    let episode: DownloadItem
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnailView(item: episode, width: 64, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finished \(episode.displayTitle)").font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                Text(episode.fileSize.map { "Delete it to free \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "Delete it from this iPhone?")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Delete") { answer(true) }
                .font(.subheadline.bold())
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("finishedEpisode.delete")
            Button { answer(false) } label: { Image(systemName: "xmark").font(.subheadline.bold()) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Keep")
                .accessibilityIdentifier("finishedEpisode.keep")
        }
        .padding(12)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .task(id: episode.id) {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { answer(false) }
        }
    }
}
