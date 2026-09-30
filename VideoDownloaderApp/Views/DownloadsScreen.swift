import SwiftData
import SwiftUI

struct DownloadsScreen: View {
    let openSource: (URL) -> Void
    @EnvironmentObject private var downloads: DownloadManager
    @Query(sort: \DownloadItem.createdAt, order: .reverse) private var items: [DownloadItem]
    @State private var searchText = ""
    @State private var showingDiagnostics = false

    private var displayed: [DownloadItem] {
        items.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }
    }
    private var active: [DownloadItem] { displayed.filter(\.isActive) }
    private var needsAttention: [DownloadItem] { displayed.filter { $0.status == .failed || $0.status == .cancelled } }
    private var finished: [DownloadItem] { displayed.filter { $0.status == .completed } }

    var body: some View {
        NavigationStack {
            List {
                if displayed.isEmpty {
                    ContentUnavailableView(items.isEmpty ? "No downloads" : "No matching downloads", systemImage: "arrow.down.circle",
                                           description: Text(items.isEmpty ? "Videos you download in Browse appear here." : "Try another search."))
                }
                if !active.isEmpty { Section("In Progress") { rows(active) } }
                if !needsAttention.isEmpty { Section("Needs Attention") { rows(needsAttention) } }
                if !finished.isEmpty { Section("Completed") { rows(finished) } }
                Section("Storage") {
                    LabeledContent("Downloads used", value: usedSpace)
                    LabeledContent("Available on iPhone", value: availableSpace)
                }
            }
            .navigationTitle("Downloads")
            .searchable(text: $searchText, prompt: "Search downloads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingDiagnostics = true } label: { Label("Error log", systemImage: "stethoscope") }
                        .accessibilityIdentifier("downloads.errorLog")
                }
            }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsScreen() }
        }
    }

    @ViewBuilder private func rows(_ group: [DownloadItem]) -> some View {
        ForEach(group) { item in
            DownloadRow(item: item, progress: downloads.progress(of: item), estimatedSeconds: downloads.estimatedSeconds(of: item),
                        cancel: { downloads.cancel(item) }, retry: { downloads.retry(item) }, restart: { downloads.restart(item) },
                        delete: { downloads.delete(item) }, openSource: { openSource(item.sourcePageURL) })
        }
        .onDelete { offsets in offsets.map { group[$0] }.forEach(downloads.delete) }
    }

    private var usedSpace: String {
        let bytes = items.filter { $0.status == .completed }.reduce(Int64(0)) { total, item in
            total + (item.fileSize ?? item.localURL.flatMap(DownloadStorage.allocatedSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var availableSpace: String {
        DownloadStorage.availableCapacity().map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let progress: Double
    let estimatedSeconds: TimeInterval?
    let cancel: () -> Void
    let retry: () -> Void
    let restart: () -> Void
    let delete: () -> Void
    let openSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind == .hls ? "play.rectangle" : "film")
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                Text(item.title).font(.headline).lineLimit(2)
            }
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("download.status")
                Spacer()
                if item.status == .downloading { Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()) }
            }
            if item.isActive { ProgressView(value: progress).accessibilityLabel("Download progress") }
            if item.requiresReferer && item.isActive {
                Text("Keep the app open until this stream finishes.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if item.isStreamFragment {
                Text("This older download is only one piece of a video. Delete it and choose a complete playlist instead.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if item.status == .downloading, let estimatedSeconds, progress > 0, progress < 1 {
                Text(estimateLabel(estimatedSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = item.errorMessage {
                Text(error.contains("CoreMediaErrorDomain") ? "The video server stopped this transfer. Open the page and try again later." : error)
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                if item.isActive { Button("Cancel", action: cancel) }
                if item.status == .failed || item.status == .cancelled {
                    if !isRateLimited { Button(canResume ? "Resume" : "Retry", action: retry).buttonStyle(.borderedProminent) }
                    if item.kind == .hls || isRateLimited { Button("Open Page", action: openSource).buttonStyle(.borderedProminent) }
                }
                Spacer()
                Menu {
                    if canResume { Button("Start Over", action: restart) }
                    Button("Delete", role: .destructive, action: delete)
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download.row")
    }

    private var statusText: String {
        if item.isStreamFragment && item.status == .completed { return "Stream fragment · not a complete video" }
        switch item.status {
        case .queued: return "Waiting"
        case .downloading: return "Downloading"
        case .completed: return "Completed" + (item.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var canResume: Bool {
        item.kind != .hls && FileManager.default.fileExists(atPath: item.resumeDataURL.path)
    }
    private var isRateLimited: Bool { item.errorMessage?.contains("HTTP 429") == true }

    private func estimateLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return "About \(minutes) min remaining" }
        return "About \(minutes / 60) hr \(minutes % 60) min remaining"
    }
}
