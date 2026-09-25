import SwiftData
import SwiftUI

struct BrowserScreen: View {
    @ObservedObject var model: BrowserViewModel
    let showDownloads: () -> Void
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bookmark.createdAt) private var bookmarks: [Bookmark]
    @State private var showingCandidates = false
    @State private var showingBookmarks = false
    @State private var showingDiagnostics = false

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
                ToolbarItem(placement: .topBarLeading) { bookmarksMenu }
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
                    if downloads.start(candidate, expectedBytes: probe?.expectedBytes, preferredBitrate: variant?.bandwidth) != nil { showDownloads() }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingBookmarks) { BookmarksSheet() }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsScreen() }
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

    private var bookmarksMenu: some View {
        Menu {
            ForEach(bookmarks) { bookmark in
                Button(bookmark.title) { model.navigate(to: bookmark.url.absoluteString) }
            }
            Divider()
            Button {
                guard let url = model.url else { return }
                modelContext.insert(Bookmark(title: model.pageTitle.isEmpty ? (url.host ?? url.absoluteString) : model.pageTitle, url: url))
                try? modelContext.save()
            } label: { Label("Add This Page", systemImage: "plus") }
            .disabled(model.url == nil)
            Button { showingBookmarks = true } label: { Label("Edit Bookmarks", systemImage: "pencil") }
            if model.diagnostics != nil {
                Divider()
                Button { showingDiagnostics = true } label: { Label("Diagnostics", systemImage: "stethoscope") }
            }
        } label: {
            Label("Bookmarks", systemImage: "book")
        }
        .accessibilityIdentifier("browser.bookmarks")
    }
}

private struct CandidateSheet: View {
    @ObservedObject var model: BrowserViewModel
    let download: (MediaCandidate, ProbeResult?, HLSVariant?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var sorted: [MediaCandidate] {
        func rank(_ candidate: MediaCandidate) -> Int {
            switch model.statuses[candidate.id] {
            case .ready?: return 0
            case .checking?, nil: return 1
            case .unavailable?: return 2
            }
        }
        return model.candidates.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            List {
                if model.candidates.isEmpty {
                    ContentUnavailableView("No videos found yet", systemImage: "film.stack",
                                           description: Text("Start playing the video on the page, then tap Refresh."))
                }
                ForEach(sorted) { candidate in
                    CandidateRow(candidate: candidate, status: model.statuses[candidate.id] ?? .checking, download: download)
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
    let download: (MediaCandidate, ProbeResult?, HLSVariant?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.title).font(.headline).lineLimit(2)
            Text(([kindLabel, candidate.quality, candidate.url.host].compactMap { $0 }).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text(candidate.url.absoluteString).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            statusView
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
        var parts = ["Ready"]
        if let bytes = probe.expectedBytes { parts.append((probe.kind == .hls ? "about " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if let duration = probe.duration, duration > 0 { parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))) }
        return parts.joined(separator: " · ")
    }
}

private struct BookmarksSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Bookmark.createdAt) private var bookmarks: [Bookmark]

    var body: some View {
        NavigationStack {
            List {
                if bookmarks.isEmpty { ContentUnavailableView("No bookmarks", systemImage: "book") }
                ForEach(bookmarks) { bookmark in
                    VStack(alignment: .leading) {
                        Text(bookmark.title)
                        Text(bookmark.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDelete { offsets in
                    offsets.map { bookmarks[$0] }.forEach(modelContext.delete)
                    try? modelContext.save()
                }
            }
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
