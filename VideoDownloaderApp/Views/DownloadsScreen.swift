import SwiftData
import SwiftUI

struct DownloadsScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Query(sort: \DownloadItem.createdAt, order: .reverse) private var items: [DownloadItem]

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Videos you download in Browse appear here."))
                }
                ForEach(items) { item in
                    DownloadRow(item: item, progress: downloads.progress(of: item),
                                cancel: { downloads.cancel(item) }, retry: { downloads.retry(item) }, delete: { downloads.delete(item) })
                }
                .onDelete { offsets in offsets.map { items[$0] }.forEach(downloads.delete) }
            }
            .navigationTitle("Downloads")
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let progress: Double
    let cancel: () -> Void
    let retry: () -> Void
    let delete: () -> Void

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
            if let error = item.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if item.isActive { Button("Cancel", action: cancel) }
                if item.status == .failed || item.status == .cancelled { Button("Retry", action: retry) }
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
        switch item.status {
        case .queued: return "Waiting"
        case .downloading: return "Downloading"
        case .completed: return "Completed" + (item.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}
