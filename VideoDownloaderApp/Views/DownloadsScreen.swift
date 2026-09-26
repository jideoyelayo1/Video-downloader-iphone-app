import SwiftData
import SwiftUI

struct DownloadsScreen: View {
    let openSource: (URL) -> Void
    @EnvironmentObject private var downloads: DownloadManager
    @Query(sort: \DownloadItem.createdAt, order: .reverse) private var items: [DownloadItem]
    @State private var searchText = ""

    private var displayed: [DownloadItem] {
        items.filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Storage") {
                    LabeledContent("Downloads used", value: usedSpace)
                    LabeledContent("Available on iPhone", value: availableSpace)
                }
                if displayed.isEmpty {
                    ContentUnavailableView(items.isEmpty ? "No downloads" : "No matching downloads", systemImage: "arrow.down.circle",
                                           description: Text(items.isEmpty ? "Videos you download in Browse appear here." : "Try another search."))
                }
                ForEach(displayed) { item in
                    DownloadRow(item: item, progress: downloads.progress(of: item), estimatedSeconds: downloads.estimatedSeconds(of: item),
                                cancel: { downloads.cancel(item) }, retry: { downloads.retry(item) }, restart: { downloads.restart(item) },
                                delete: { downloads.delete(item) },
                                openSource: { openSource(item.sourcePageURL) })
                }
                .onDelete { offsets in offsets.map { displayed[$0] }.forEach(downloads.delete) }
            }
            .navigationTitle("Downloads")
            .searchable(text: $searchText, prompt: "Search downloads")
        }
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
            HStack {
                Image(systemName: item.kind == .hls ? "dot.radiowaves.left.and.right" : "film").foregroundStyle(.secondary)
                Text(item.title).font(.headline).lineLimit(2)
            }
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("download.status")
                Spacer()
                if item.status == .downloading { Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()) }
            }
            if item.status != .completed { ProgressView(value: progress).accessibilityLabel("Download progress") }
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
            if let error = item.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if item.isActive { Button("Cancel", action: cancel) }
                if item.status == .failed || item.status == .cancelled {
                    Button(canResume ? "Resume" : "Retry", action: retry)
                    if canResume { Button("Start Over", action: restart) }
                }
                if item.status == .failed && item.kind == .hls { Button("Open Page", action: openSource) }
                Spacer()
                Button("Delete", role: .destructive, action: delete)
            }
            .buttonStyle(.bordered)
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

    private func estimateLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return "About \(minutes) min remaining" }
        return "About \(minutes / 60) hr \(minutes % 60) min remaining"
    }
}
