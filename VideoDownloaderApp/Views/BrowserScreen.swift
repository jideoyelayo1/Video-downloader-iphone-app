import SwiftData
import SwiftUI

struct BrowserScreen: View {
    @ObservedObject var model: BrowserViewModel
    let showDownloads: () -> Void
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showingCandidates = false
    @State private var showingCollections = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if model.isLoading { ProgressView().progressViewStyle(.linear).accessibilityLabel("Loading page") }
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
                        Label(model.candidates.isEmpty ? "Found videos" : "Found videos (\(model.candidates.count))", systemImage: "film.stack")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("browser.foundVideos")
                    .accessibilityValue("\(model.readyCount) ready")
                }
            }
            .sheet(isPresented: $showingCandidates) {
                CandidateSheet(model: model) { candidate, probe, variant in
                    var candidate = candidate
                    candidate.kind = probe?.kind ?? candidate.kind
                    showingCandidates = false
                    if downloads.start(candidate, expectedBytes: probe?.expectedBytes, preferredBitrate: variant?.bandwidth,
                                       requiresReferer: probe?.requiresReferer ?? false) != nil { showDownloads() }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingCollections) {
                BrowserCollectionsSheet(currentURL: model.url, currentTitle: model.pageTitle) { url in
                    model.navigate(to: url.absoluteString)
                }
            }
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
                .onSubmit { model.navigate(to: model.addressText) }
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

private struct CandidateSheet: View {
    @ObservedObject var model: BrowserViewModel
    let download: (MediaCandidate, ProbeResult?, HLSVariant?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var sorted: [MediaCandidate] {
        func rank(_ candidate: MediaCandidate) -> Int {
            switch model.statuses[candidate.id] {
            case .ready(let probe)?: return probe.kind == .hls && !probe.variants.isEmpty ? 0 : 1
            case .checking?, nil: return 2
            case .unavailable?: return 3
            }
        }
        return model.candidates.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
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
                }
                ForEach(sorted) { candidate in
                    CandidateRow(candidate: candidate, status: model.statuses[candidate.id] ?? .checking,
                                 masterAvailable: model.statuses.values.contains(where: {
                        if case .ready(let probe) = $0 { return probe.kind == .hls && !probe.variants.isEmpty }
                        return false
                    }), download: download)
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
}

private struct CandidateRow: View {
    let candidate: MediaCandidate
    let status: CandidateStatus
    let masterAvailable: Bool
    let download: (MediaCandidate, ProbeResult?, HLSVariant?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.title).font(.headline).lineLimit(2)
            Text(([kindLabel, candidate.quality, candidate.url.host].compactMap { $0 }).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text(candidate.url.absoluteString).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            statusView
            if masterAvailable, case .ready(let probe) = status, probe.kind == .hls, probe.variants.isEmpty {
                Text("Choose the master playlist above when available; this single playlist may omit separate audio or captions.")
                    .font(.caption).foregroundStyle(.orange)
            }
            downloadControl
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("candidate.\(candidate.url.lastPathComponent)")
    }

    private var kindLabel: String {
        if case .ready(let probe) = status { return probe.kind.label }
        return candidate.kind.label
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .checking:
            Label("Checking…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .ready(let probe):
            Label(readyDetail(probe), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .unavailable(let error):
            Label(error.message, systemImage: error == .protectedStream ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var downloadControl: some View {
        if case .ready(let probe) = status, probe.variants.count > 1 {
            Menu {
                Button("Best quality") { download(candidate, probe, nil) }
                // Variants can share a playlist URL (e.g. across audio groups), so rows are keyed by position.
                ForEach(Array(probe.variants.enumerated()), id: \.offset) { _, variant in
                    Button(variant.qualityLabel) { download(candidate, probe, variant) }
                }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("candidate.download")
        } else {
            Button {
                if case .ready(let probe) = status { download(candidate, probe, nil) }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .buttonStyle(.borderedProminent)
            .disabled(!status.isReady)
            .accessibilityIdentifier("candidate.download")
        }
    }

    private func readyDetail(_ probe: ProbeResult) -> String {
        var parts = [probe.requiresReferer ? "Ready · keep app open" : "Ready"]
        if probe.kind == .hls && !probe.variants.isEmpty { parts.append("Master playlist") }
        if let bytes = probe.expectedBytes { parts.append((probe.kind == .hls ? "about " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if let duration = probe.duration, duration > 0 { parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))) }
        return parts.joined(separator: " · ")
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
        if let currentURL, ["http", "https"].contains(currentURL.scheme?.lowercased() ?? "") {
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
        Section("Saved Sites") {
            if visibleBookmarks.isEmpty {
                ContentUnavailableView(searchText.isEmpty ? "No bookmarks" : "No matching bookmarks", systemImage: "bookmark",
                                       description: Text(searchText.isEmpty ? "Save a site or page to find it here." : "Try another search."))
            }
            ForEach(visibleBookmarks) { bookmark in
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
