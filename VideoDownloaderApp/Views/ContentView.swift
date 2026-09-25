import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var browser = BrowserViewModel(diagnostics: LaunchOptions.diagnosticsEnabled ? AppServices.shared.diagnostics : nil)
    @State private var selection = Tab.browse

    enum Tab { case browse, downloads, library }

    var body: some View {
        TabView(selection: $selection) {
            BrowserScreen(model: browser, showDownloads: { selection = .downloads })
                .tabItem { Label("Browse", systemImage: "safari") }
                .tag(Tab.browse)
            DownloadsScreen()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)
            LibraryScreen()
                .tabItem { Label("Library", systemImage: "play.rectangle") }
                .tag(Tab.library)
        }
        .alert("Can't start download", isPresented: Binding(get: { downloads.startError != nil }, set: { if !$0 { downloads.startError = nil } })) {
            Button("OK", role: .cancel) { downloads.startError = nil }
        } message: { Text(downloads.startError ?? "") }
    }
}
