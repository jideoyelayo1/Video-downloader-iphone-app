import AVKit
import SwiftData
import SwiftUI
import UIKit

struct LibraryScreen: View {
    var showBrowse: () -> Void = {}
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Query(filter: #Predicate<DownloadItem> { $0.statusRaw == "completed" }, sort: \DownloadItem.completedAt, order: .reverse)
    private var completed: [DownloadItem]
    @Query(sort: \DownloadFolder.title) private var folders: [DownloadFolder]
    @Environment(\.modelContext) private var modelContext
    @State private var pendingPlayback: DownloadItem?
    @State private var renaming: DownloadItem?
    @State private var newTitle = ""
    @State private var searchText = ""
    @State private var selectedFolderID: UUID?
    @State private var showingNewFolder = false
    @State private var showingManageFolders = false
    @State private var newFolderTitle = ""
    @State private var expiryWarningDismissed = false

    private var displayed: [DownloadItem] {
        completed.filter { item in
            !item.isStreamFragment &&
            (selectedFolderID == nil || item.folderID == selectedFolderID) &&
            (searchText.isEmpty || item.title.localizedStandardContains(searchText))
        }
    }

    private var playableCompletedCount: Int { completed.filter { !$0.isStreamFragment }.count }
    private var continueWatching: [DownloadItem] {
        completed.filter { !$0.isStreamFragment && ($0.playbackPosition ?? 0) > 10 }
            .sorted { ($0.playbackPosition ?? 0) > ($1.playbackPosition ?? 0) }
    }

    var body: some View {
        // Each list is filtered once per render instead of once per use.
        let displayed = displayed
        let continueWatching = continueWatching
        NavigationStack {
            List {
                if !expiryWarningDismissed, let warning = BuildExpiry.warning(expiry: BuildExpiry.date) {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(warning).font(.subheadline)
                                .accessibilityIdentifier("library.expiryWarning")
                            Spacer(minLength: 0)
                            Button { expiryWarningDismissed = true } label: {
                                Image(systemName: "xmark").font(.subheadline.bold()).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss")
                        }
                    }
                }
                if selectedFolderID == nil && searchText.isEmpty && !continueWatching.isEmpty {
                    Section("Continue Watching") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(continueWatching) { item in
                                    VStack(alignment: .leading, spacing: 7) {
                                        Button { start(item, at: item.playbackPosition ?? 0) } label: {
                                            VideoThumbnailView(item: item, width: 174, height: 98)
                                        }
                                        .buttonStyle(.plain)
                                        HStack(alignment: .top, spacing: 4) {
                                            Text(item.title).font(.subheadline.bold()).lineLimit(2)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 0)
                                            Menu { actions(for: item) } label: {
                                                Image(systemName: "ellipsis.circle")
                                                    .accessibilityLabel("More options for \(item.title)")
                                            }
                                        }
                                        Text(item.downloadedText).font(.caption2).foregroundStyle(.secondary)
                                        Label("Resume", systemImage: "play.fill")
                                            .font(.caption).foregroundStyle(.tint)
                                    }
                                    .frame(width: 174, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if displayed.isEmpty {
                    VStack(spacing: 14) {
                        ContentUnavailableView(playableCompletedCount == 0 ? "Your library is empty" : "No matching videos", systemImage: "play.rectangle",
                                               description: Text(playableCompletedCount == 0 ? "Completed downloads play here, even offline." : "Try another search or folder."))
                        if playableCompletedCount == 0 {
                            Button { showBrowse() } label: { Label("Find a video", systemImage: "safari") }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                Section(displayed.isEmpty ? "" : "All Videos") {
                    ForEach(displayed) { item in
                        HStack(spacing: 4) {
                            Button { open(item) } label: { LibraryRow(item: item) }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("library.item")
                            Menu { actions(for: item) } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .frame(minWidth: 40, minHeight: 44)
                                    .accessibilityLabel("More options for \(item.title)")
                            }
                            .accessibilityIdentifier("library.moreOptions")
                        }
                        .contextMenu { actions(for: item) }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { downloads.delete(item) }
                            Button("Rename") { beginRename(item) }.tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("My Videos")
            .searchable(text: $searchText, prompt: "Search videos")
            .onChange(of: folders.map(\.id)) { _, ids in
                if let selectedFolderID, !ids.contains(selectedFolderID) { self.selectedFolderID = nil }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All Videos") { selectedFolderID = nil }
                        ForEach(folders) { folder in
                            Button(folder.title) { selectedFolderID = folder.id }
                        }
                        Divider()
                        Button("New Folder", systemImage: "folder.badge.plus") { newFolderTitle = ""; showingNewFolder = true }
                        Button("Manage Folders", systemImage: "folder") { showingManageFolders = true }
                    } label: { Label("Folders", systemImage: "folder") }
                        .accessibilityIdentifier("library.folders")
                }
            }
            .sheet(isPresented: $showingManageFolders) { ManageFoldersSheet() }
            .confirmationDialog("Play video", isPresented: Binding(get: { pendingPlayback != nil }, set: { if !$0 { pendingPlayback = nil } })) {
                Button("Resume") { if let item = pendingPlayback { start(item, at: item.playbackPosition ?? 0) }; pendingPlayback = nil }
                Button("Start from Beginning") { if let item = pendingPlayback { start(item, at: 0) }; pendingPlayback = nil }
            } message: { Text("Continue where you stopped or play from the beginning?") }
            .alert("New Folder", isPresented: $showingNewFolder) {
                TextField("Folder name", text: $newFolderTitle)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Rename video", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") { if let renaming { downloads.rename(renaming, to: newTitle) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    @ViewBuilder private func actions(for item: DownloadItem) -> some View {
        Button { beginRename(item) } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            Button("No Folder") { item.folderID = nil; try? modelContext.save() }
            ForEach(folders) { folder in
                Button(folder.title) { item.folderID = folder.id; try? modelContext.save() }
            }
        } label: { Label("Move to Folder", systemImage: "folder") }
        if item.kind != .hls, let url = item.localURL {
            ShareLink(item: url, preview: SharePreview(item.title)) { Label("Export", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) { downloads.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private func beginRename(_ item: DownloadItem) {
        newTitle = item.title
        renaming = item
    }

    private func open(_ item: DownloadItem) {
        if (item.playbackPosition ?? 0) > 10 { pendingPlayback = item }
        else { start(item, at: 0) }
    }

    private func start(_ item: DownloadItem, at position: Double) {
        if position == 0 { item.playbackPosition = 0; try? modelContext.save() }
        playback.open(item, at: position)
    }

    private func createFolder() {
        let title = newFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let folder = DownloadFolder(title: title)
        modelContext.insert(folder)
        try? modelContext.save()
        selectedFolderID = folder.id
    }
}

private struct ManageFoldersSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DownloadFolder.title) private var folders: [DownloadFolder]
    @Query private var items: [DownloadItem]

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders) { folder in Label(folder.title, systemImage: "folder") }
                    .onDelete { offsets in
                        for folder in offsets.map({ folders[$0] }) {
                            for item in items where item.folderID == folder.id { item.folderID = nil }
                            modelContext.delete(folder)
                        }
                        try? modelContext.save()
                    }
            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct LibraryRow: View {
    let item: DownloadItem
    @State private var duration: Double?

    var body: some View {
        let fileExists = fileExists
        HStack(spacing: 12) {
            VideoThumbnailView(item: item, width: 112, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                // Date and size on their own lines: together they always wrap mid-way at this width.
                Text(item.downloadedText).font(.caption).foregroundStyle(.secondary)
                if !fileExists {
                    Text("File missing").font(.caption).foregroundStyle(.red)
                } else if let size = item.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                if (item.playbackPosition ?? 0) > 10 {
                    Label("Continue watching", systemImage: "play.circle.fill")
                        .font(.caption2).foregroundStyle(.tint)
                    if let duration, duration > 0 {
                        ProgressView(value: min((item.playbackPosition ?? 0) / duration, 1))
                            .tint(.cyan)
                            .accessibilityLabel("Playback progress")
                    }
                }
            }
        }
        .task(id: item.localFileName) {
            guard let url = item.localURL, let fileName = item.localFileName, (item.playbackPosition ?? 0) > 10 else { return }
            duration = await ThumbnailCache.shared.duration(of: url, fileName: fileName)
        }
    }

    private var fileExists: Bool { item.localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

private struct VideoThumbnailView: View {
    let item: DownloadItem
    var width: CGFloat = 72
    var height: CGFloat = 48
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? ThumbnailCache.shared.cachedImage(for: item.id, fileName: item.localFileName) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").font(.title2).foregroundStyle(.tint)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.localFileName) {
            // The body falls back to the in-memory cache, so clearing this doesn't flash a placeholder.
            image = nil
            image = await ThumbnailCache.shared.image(for: item.id, fileName: item.localFileName, mediaURL: item.localURL, kind: item.kind)
        }
    }
}
