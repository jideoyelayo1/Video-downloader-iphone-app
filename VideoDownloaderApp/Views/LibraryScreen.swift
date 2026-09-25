import AVKit
import SwiftData
import SwiftUI

struct LibraryScreen: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Query(filter: #Predicate<DownloadItem> { $0.statusRaw == "completed" }, sort: \DownloadItem.completedAt, order: .reverse)
    private var completed: [DownloadItem]
    @State private var playing: DownloadItem?
    @State private var renaming: DownloadItem?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if completed.isEmpty {
                    ContentUnavailableView("Your library is empty", systemImage: "play.rectangle",
                                           description: Text("Completed downloads play here, even offline."))
                }
                ForEach(completed) { item in
                    Button { playing = item } label: { LibraryRow(item: item) }
                        .accessibilityIdentifier("library.item")
                        .contextMenu { actions(for: item) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { downloads.delete(item) }
                            Button("Rename") { beginRename(item) }.tint(.blue)
                        }
                }
            }
            .navigationTitle("Library")
            .sheet(item: $playing) { item in PlayerScreen(item: item) }
            .alert("Rename video", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") { if let renaming { downloads.rename(renaming, to: newTitle) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    @ViewBuilder private func actions(for item: DownloadItem) -> some View {
        Button { beginRename(item) } label: { Label("Rename", systemImage: "pencil") }
        if item.kind != .hls, let url = item.localURL {
            ShareLink(item: url, preview: SharePreview(item.title)) { Label("Export", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) { downloads.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private func beginRename(_ item: DownloadItem) {
        newTitle = item.title
        renaming = item
    }
}

private struct LibraryRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .hls ? "dot.radiowaves.left.and.right" : "film")
                .font(.title2).frame(width: 36).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(fileExists ? Color.secondary : Color.red)
            }
        }
    }

    private var fileExists: Bool { item.localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    private var detail: String {
        guard fileExists else { return "File missing — delete and download again" }
        var parts: [String] = []
        if let size = item.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let date = item.completedAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

struct PlayerScreen: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let url = item.localURL, FileManager.default.fileExists(atPath: url.path) {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom).accessibilityIdentifier("player.video")
                } else {
                    ContentUnavailableView("File unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // HLS packages can only be played inside the app.
                    if item.kind != .hls, let url = item.localURL {
                        ShareLink(item: url, preview: SharePreview(item.title)) { Label("Export", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("player.export")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear {
                guard let url = item.localURL else { return }
                player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
                player?.play()
            }
            .onDisappear { player?.pause(); player = nil }
        }
    }
}
