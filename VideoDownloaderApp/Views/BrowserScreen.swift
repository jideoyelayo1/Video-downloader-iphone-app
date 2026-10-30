import SwiftData
import SwiftUI

struct BrowserScreen: View {
    @ObservedObject var model: BrowserViewModel
    let showDownloads: () -> Void
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var seasons: SeasonDownloader
    @State private var showingCandidates = false
    @State private var showingCollections = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                    // Drawn over the bar's bottom edge so the page doesn't shift on every load.
                    .overlay(alignment: .bottom) {
                        if model.isLoading {
                            ProgressView(value: max(model.loadProgress, 0.05))
                                .progressViewStyle(.linear)
                                .tint(.cyan)
                                .allowsHitTesting(false)
                                .accessibilityLabel("Loading page")
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: model.isLoading)
                BrowserView(model: model)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(model.pageTitle.isEmpty ? "Browse" : model.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingCollections = true } label: { Label("Bookmarks and History", systemImage: "book.closed") }
                        .accessibilityIdentifier("browser.bookmarks")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCandidates = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "film.stack")
                            FoundVideosCount(total: model.candidates.count, ready: model.readyCount)
                        }
                    }
                    .accessibilityLabel(model.candidates.isEmpty ? "Found videos" : "Found videos (\(model.candidates.count))")
                    .accessibilityIdentifier("browser.foundVideos")
                    .accessibilityValue("\(model.readyCount) ready")
                }
            }
            .sheet(isPresented: $showingCandidates) {
                CandidateSheet(model: model, download: { candidate, probe, variant in
                    var candidate = candidate
                    candidate.kind = probe?.kind ?? candidate.kind
                    showingCandidates = false
                    if downloads.start(candidate, expectedBytes: probe?.expectedBytes, preferredBitrate: variant?.bandwidth,
                                       requiresReferer: probe?.requiresReferer ?? false, subtitles: model.subtitleTracks,
                                       poster: model.posterURL) != nil { showDownloads() }
                }, downloadNextEpisodes: { count in
                    guard let page = model.url else { return }
                    showingCandidates = false
                    seasons.start(after: page, count: count)
                    showDownloads()
                })
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingCollections) {
                BrowserCollectionsSheet(currentURL: model.url, currentTitle: model.pageTitle) { url in
                    model.navigate(to: url.absoluteString)
                }
            }
            .onDisappear { addressFocused = false }
            .alert("Browser error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 12) {
            Button(action: model.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack).accessibilityLabel("Back")
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).accessibilityLabel("Forward")
            TextField("Website address", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onChange(of: addressFocused) { _, focused in model.isEditingAddress = focused }
                .onSubmit {
                    // Otherwise the field keeps focus, and the keyboard returns later over other screens.
                    addressFocused = false
                    model.navigate(to: model.addressText)
                }
                .accessibilityIdentifier("browser.address")
                .overlay(alignment: .trailing) {
                    if !model.addressText.isEmpty {
                        Button { model.addressText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .padding(.trailing, 6)
                            .accessibilityLabel("Clear address")
                    }
                }
            Button(action: model.reload) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

}

/// How many videos the page offers, beside the toolbar icon, so results show without opening the sheet.
/// Green once one is ready to save.
private struct FoundVideosCount: View {
    let total: Int
    let ready: Int

    var body: some View {
        if total > 0 {
            Text("\(ready > 0 ? ready : total)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(ready > 0 ? Color.green : Color.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct CandidateSheet: View {
    @ObservedObject var model: BrowserViewModel
    let download: (MediaCandidate, ProbeResult?, HLSVariant?) -> Void
    var downloadNextEpisodes: (Int) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var seasons: SeasonDownloader
    @State private var nextEpisodeCount = 3

    private enum Group: Int, CaseIterable {
        case ready, checking, unavailable
        var title: String {
            switch self {
            case .ready: return "Ready to Save"
            case .checking: return "Checking"
            case .unavailable: return "Can't Be Saved"
            }
        }
    }

    private func group(of candidate: MediaCandidate) -> Group {
        switch model.statuses[candidate.id] {
        case .ready?: return .ready
        case .checking?, nil: return .checking
        case .unavailable?: return .unavailable
        }
    }

    /// Master playlists first: they carry every quality plus separate audio and captions.
    private func candidates(in group: Group) -> [MediaCandidate] {
        let members = model.candidates.enumerated().filter { self.group(of: $0.element) == group }
        return members.sorted { a, b in
            let rank = { (candidate: MediaCandidate) -> Int in
                if case .ready(let probe)? = model.statuses[candidate.id], probe.kind == .hls, !probe.variants.isEmpty { return 0 }
                return 1
            }
            return (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)
    }

    private var masterAvailable: Bool {
        model.statuses.values.contains {
            if case .ready(let probe) = $0 { return probe.kind == .hls && !probe.variants.isEmpty }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.candidates.isEmpty {
                    if model.observedFragments {
                        ContentUnavailableView("Stream pieces found", systemImage: "square.stack.3d.up.slash",
                                               description: Text("The player is loading video fragments, but no complete HLS playlist was found. Try another server on the page, then tap Refresh."))
                    } else {
                        ContentUnavailableView("No videos found yet", systemImage: "film.stack",
                                               description: Text("Complete any site verification, start the video on the page, then tap Refresh. Some protected streams cannot be saved."))
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.pageTitle.isEmpty ? "This page" : model.pageTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text("Downloads are named after this page.").font(.caption).foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                    }
                }
                ForEach(Group.allCases, id: \.self) { group in
                    let members = candidates(in: group)
                    if !members.isEmpty {
                        Section(group.title) {
                            ForEach(members) { candidate in
                                CandidateRow(candidate: candidate, status: model.statuses[candidate.id] ?? .checking,
                                             masterAvailable: masterAvailable, download: download)
                            }
                        }
                    }
                }
                if !model.subtitleTracks.isEmpty && !model.candidates.isEmpty {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.subtitleTracks.count == 1 ? "1 subtitle language" : "\(model.subtitleTracks.count) subtitle languages")
                                    .font(.subheadline.weight(.semibold))
                                Text(Self.summary(model.subtitleTracks.map(\.displayName))).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "captions.bubble").foregroundStyle(.tint) }
                        .accessibilityIdentifier("candidate.subtitles")
                    } footer: {
                        Text("Saved with your download. Choose them from Captions when you play it in My Videos.")
                    }
                }
                if model.readyCount > 0, let page = model.url, EpisodeURL.next(after: page) != nil {
                    Section {
                        Stepper("Next \(nextEpisodeCount) \(nextEpisodeCount == 1 ? "episode" : "episodes")", value: $nextEpisodeCount, in: 1...24)
                            .accessibilityIdentifier("season.count")
                        Button {
                            downloadNextEpisodes(nextEpisodeCount)
                        } label: { Label("Download Next Episodes", systemImage: "square.stack.3d.down.forward") }
                            .disabled(seasons.isRunning)
                            .accessibilityIdentifier("season.download")
                    } header: {
                        Text("Season")
                    } footer: {
                        Text("Opens each next episode's page in the background, finds its video and downloads it. Stops at an episode that isn't out yet.")
                    }
                }
            }
            .navigationTitle("Found videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.rescan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    static func summary(_ names: [String], shown: Int = 3) -> String {
        let listed = names.prefix(shown).joined(separator: ", ")
        return names.count > shown ? "\(listed) and \(names.count - shown) more" : listed
    }
}

private struct CandidateRow: View {
    let candidate: MediaCandidate
    let status: CandidateStatus
    let masterAvailable: Bool
    let download: (MediaCandidate, ProbeResult?, HLSVariant?) -> Void

    private var probe: ProbeResult? {
        if case .ready(let probe) = status { return probe }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(probe != nil ? Color.accentColor : Color.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.headline).lineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                statusView
                if let spaceWarning {
                    Label(spaceWarning, systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
                }
                if masterAvailable, let probe, probe.kind == .hls, probe.variants.isEmpty {
                    Text("The master playlist above also includes every quality, audio and caption track.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if probe != nil { downloadControl.padding(.top, 4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = candidate.url }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("candidate.\(candidate.url.lastPathComponent)")
    }

    private var symbol: String {
        switch probe?.kind ?? candidate.kind {
        case .hls: return probe?.variants.isEmpty == false ? "play.rectangle.on.rectangle" : "play.rectangle"
        case .video: return "film"
        case .unknown: return "questionmark.video"
        }
    }

    private var headline: String {
        guard let probe else { return candidate.kind == .hls ? "Stream" : "Video" }
        if probe.kind == .hls {
            if let best = probe.variants.first { return "Master playlist · up to \(best.qualityLabel)" }
            return "Single-quality stream"
        }
        return ["Video file", candidate.quality].compactMap { $0 }.joined(separator: " · ")
    }

    private var details: String {
        // The headline already says "Video file"; streams keep their kind here.
        var parts: [String] = (probe?.kind ?? candidate.kind) == .video ? [] : [probe?.kind.label ?? candidate.kind.label]
        if let probe {
            if let bytes = probe.expectedBytes { parts.append((probe.kind == .hls ? "about " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            if let duration = probe.duration, duration > 0 {
                parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
        }
        if let host = candidate.url.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    /// Shown before downloading when the video won't fit in the space left.
    private var spaceWarning: String? {
        guard let bytes = probe?.expectedBytes, let free = DownloadStorage.availableCapacity(), bytes > free else { return nil }
        return "Needs " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + ", but only "
            + ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " is free."
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .ready(let probe):
            Label(probe.requiresReferer ? "Ready · keep app open" : "Ready", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .unavailable(let error):
            Label(error.message, systemImage: error == .protectedStream ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var downloadControl: some View {
        if let probe, probe.variants.count > 1 {
            Menu {
                Button("Best quality") { download(candidate, probe, nil) }
                // Variants can share a playlist URL (e.g. across audio groups), so rows are keyed by position.
                ForEach(Array(probe.variants.enumerated()), id: \.offset) { _, variant in
                    Button(variant.menuTitle(duration: probe.duration)) { download(candidate, probe, variant) }
                }
            } label: { Label("Download", systemImage: "arrow.down") }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("candidate.download")
        } else if let probe {
            Button { download(candidate, probe, nil) } label: { Label("Download", systemImage: "arrow.down") }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityIdentifier("candidate.download")
        }
    }
}

private struct BrowserCollectionsSheet: View {
    enum Collection: String, CaseIterable { case bookmarks = "Bookmarks", history = "History" }

    let currentURL: URL?
    let currentTitle: String
    let navigate: (URL) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Bookmark.createdAt) private var bookmarks: [Bookmark]
    @Query(sort: \BrowsingHistoryEntry.visitedAt, order: .reverse) private var history: [BrowsingHistoryEntry]
    @State private var collection = Collection.bookmarks
    @State private var searchText = ""
    @State private var renaming: Bookmark?
    @State private var newTitle = ""
    @State private var showingClearHistory = false
    @State private var showingDiagnostics = false

    private var visibleBookmarks: [Bookmark] {
        bookmarks.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText)
            || $0.url.absoluteString.localizedStandardContains(searchText) }
    }

    private var visibleHistory: [BrowsingHistoryEntry] {
        history.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText)
            || $0.url.absoluteString.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Collection", selection: $collection) {
                    ForEach(Collection.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .accessibilityIdentifier("browser.collectionPicker")
                List {
                    if collection == .bookmarks { bookmarksContent }
                    else { historyContent }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(collection.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: collection == .bookmarks ? "Search bookmarks" : "Search history")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingDiagnostics = true } label: { Label("Diagnostics", systemImage: "stethoscope") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsScreen() }
            .alert("Rename bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newTitle)
                Button("Save") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let renaming, !title.isEmpty { renaming.title = title; try? modelContext.save() }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Clear all browsing history?", isPresented: $showingClearHistory) {
                Button("Clear All History", role: .destructive) {
                    history.forEach(modelContext.delete)
                    try? modelContext.save()
                }
            } message: { Text("This removes every page in History from this device.") }
        }
    }

    @ViewBuilder private var bookmarksContent: some View {
        if let currentURL, currentURL.isWeb {
            Section {
                Button {
                    guard !bookmarks.contains(where: { $0.url == currentURL }) else { return }
                    let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    modelContext.insert(Bookmark(title: title.isEmpty ? (currentURL.host ?? currentURL.absoluteString) : title, url: currentURL))
                    try? modelContext.save()
                } label: {
                    Label(bookmarks.contains(where: { $0.url == currentURL }) ? "Page Bookmarked" : "Add This Page",
                          systemImage: bookmarks.contains(where: { $0.url == currentURL }) ? "bookmark.fill" : "bookmark.badge.plus")
                }
                .disabled(bookmarks.contains(where: { $0.url == currentURL }))
                .accessibilityIdentifier("browser.addBookmark")
            }
        }
        if visibleBookmarks.isEmpty {
            ContentUnavailableView(searchText.isEmpty ? "No bookmarks" : "No matching bookmarks", systemImage: "bookmark",
                                   description: Text(searchText.isEmpty ? "Save a site or page to find it here." : "Try another search."))
        }
        let groups = Dictionary(grouping: visibleBookmarks, by: \.folder)
        ForEach(Bookmark.Folder.allCases.filter { groups[$0] != nil }, id: \.self) { folder in
            Section {
                bookmarkRows(groups[folder] ?? [])
            } header: { Text(folder.rawValue) } footer: { if !folder.footer.isEmpty { Text(folder.footer) } }
        }
    }

    @ViewBuilder private func bookmarkRows(_ bookmarks: [Bookmark]) -> some View {
        ForEach(bookmarks) { bookmark in
            HStack(spacing: 8) {
                Button {
                    navigate(bookmark.url)
                    dismiss()
                } label: { BrowserCollectionRow(title: bookmark.title, detail: bookmark.url.host ?? "") }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("bookmark.site")
                Menu {
                    Button("Rename", systemImage: "pencil") { newTitle = bookmark.title; renaming = bookmark }
                    Button("Delete", systemImage: "trash", role: .destructive) { modelContext.delete(bookmark); try? modelContext.save() }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 40, minHeight: 44) }
                    .accessibilityLabel("More options for \(bookmark.title)")
            }
            .swipeActions { Button("Delete", role: .destructive) { modelContext.delete(bookmark); try? modelContext.save() } }
        }
    }

    @ViewBuilder private var historyContent: some View {
        Section {
            if visibleHistory.isEmpty {
                ContentUnavailableView(searchText.isEmpty ? "No history yet" : "No matching pages", systemImage: "clock.arrow.circlepath",
                                       description: Text(searchText.isEmpty ? "Pages you visit in Browse will appear here." : "Try another search."))
            }
            ForEach(visibleHistory) { entry in
                Button {
                    navigate(entry.url)
                    dismiss()
                } label: {
                    BrowserCollectionRow(title: entry.title,
                                         detail: "\(entry.url.host ?? "") · \(entry.visitedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.page")
                .swipeActions { Button("Delete", role: .destructive) { modelContext.delete(entry); try? modelContext.save() } }
            }
        } header: {
            HStack {
                Text("Recently Visited")
                Spacer()
                if !history.isEmpty {
                    Button("Clear All") { showingClearHistory = true }
                        .font(.caption)
                        .accessibilityIdentifier("history.clearAll")
                }
            }
        }
    }
}

private struct BrowserCollectionRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.headline)
                .foregroundStyle(.cyan)
                .frame(width: 38, height: 38)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
