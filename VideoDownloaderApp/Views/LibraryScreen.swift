import AVKit
import SwiftData
import SwiftUI
import UIKit

struct LibraryScreen: View {
    var showBrowse: () -> Void = {}
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var showStore: ShowStore
    @Query(filter: #Predicate<DownloadItem> { $0.statusRaw == "completed" }, sort: \DownloadItem.completedAt, order: .reverse)
    private var completed: [DownloadItem]
    @Query(sort: \DownloadFolder.title) private var folders: [DownloadFolder]
    @Query(sort: \VideoLabel.name) private var allLabels: [VideoLabel]
    @Query(sort: \Show.title) private var shows: [Show]
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
    @State private var showingManageLabels = false
    @State private var labelingItem: DownloadItem?
    @State private var newLabelName = ""
    @State private var newShowSeed: NewShowSeed?
    @State private var openedShow: Show?
    @State private var importingBackup = false
    @State private var restoreMessage: String?
    @AppStorage("librarySort", store: AppServices.shared.preferences) private var sortRaw = LibraryQuery.Sort.newest.rawValue
    @AppStorage("libraryStatus", store: AppServices.shared.preferences) private var statusRaw = LibraryQuery.Status.all.rawValue
    @AppStorage("libraryLabels", store: AppServices.shared.preferences) private var labelFilterRaw = ""

    private var query: LibraryQuery {
        // Labels deleted since they were chosen drop out of the filter.
        let existing = Set(allLabels.map(\.id))
        return LibraryQuery(sort: LibraryQuery.Sort(rawValue: sortRaw) ?? .newest,
                            status: LibraryQuery.Status(rawValue: statusRaw) ?? .all,
                            labelIDs: labelFilter.intersection(existing),
                            folderID: selectedFolderID, searchText: searchText)
    }

    private var labelFilter: Set<UUID> { Set(labelFilterRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }

    private func setLabelFilter(_ id: UUID, _ on: Bool) {
        var ids = labelFilter
        if on { ids.insert(id) } else { ids.remove(id) }
        labelFilterRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private var playableCompletedCount: Int { completed.filter { !$0.isStreamFragment }.count }
    /// Started but not finished, most recently played first.
    private var continueWatching: [DownloadItem] { ShowPlaylist.continueWatching(completed) }

    var body: some View {
        // Each list is filtered once per render instead of once per use.
        let query = query
        let displayed = query.apply(to: completed)
        let continueWatching = continueWatching
        let labelsByID = Dictionary(allLabels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                expiryWarning
                if selectedFolderID == nil && searchText.isEmpty && !query.isFiltering && !continueWatching.isEmpty {
                    continueWatchingSection(continueWatching)
                }
                if selectedFolderID == nil && searchText.isEmpty && !query.isFiltering { showsSection }
                if displayed.isEmpty { emptyState }
                allVideosSection(displayed, labelsByID: labelsByID)
            }
            // Outside the list: on iOS 18 a list row swallows taps on buttons in a scroll view.
            .safeAreaInset(edge: .top, spacing: 0) {
                if query.isFiltering || selectedFolderID != nil { filterChips(query) }
            }
            .navigationTitle("My Videos")
            .searchable(text: $searchText, prompt: "Search videos")
            .onChange(of: folders.map(\.id)) { _, ids in
                if let selectedFolderID, !ids.contains(selectedFolderID) { self.selectedFolderID = nil }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sortAndFilterMenu(query) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All Videos") { selectedFolderID = nil }
                        ForEach(folders) { folder in
                            Button(folder.title) { selectedFolderID = folder.id }
                        }
                        Divider()
                        Button("New Folder", systemImage: "folder.badge.plus") { newFolderTitle = ""; showingNewFolder = true }
                        Button("Manage Folders", systemImage: "folder") { showingManageFolders = true }
                        Button("Manage Labels", systemImage: "tag") { showingManageLabels = true }
                        Divider()
                        ShareLink(item: LibraryBackupFile(backup: LibraryBackup.make(from: modelContext)),
                                  preview: SharePreview("Video Downloader Library")) {
                            Label("Back Up Library", systemImage: "square.and.arrow.up")
                        }
                        Button("Restore from Backup…", systemImage: "square.and.arrow.down") { importingBackup = true }
                    } label: { Label("Folders", systemImage: "folder") }
                        .accessibilityIdentifier("library.folders")
                }
            }
            .sheet(isPresented: $showingManageFolders) { ManageFoldersSheet() }
            .sheet(isPresented: $showingManageLabels) { ManageLabelsSheet() }
            .sheet(item: $newShowSeed) { NewShowSheet(seed: $0) }
            .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in restore(result) }
            .alert("Library restored", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) { restoreMessage = nil }
            } message: { Text(restoreMessage ?? "") }
            .navigationDestination(item: $openedShow) { ShowScreen(show: $0) }
            .alert("New Label", isPresented: Binding(get: { labelingItem != nil }, set: { if !$0 { labelingItem = nil } })) {
                TextField("Label name", text: $newLabelName)
                Button("Add") {
                    if let item = labelingItem, let label = labelStore.create(name: newLabelName), item.labelIDs?.contains(label.id) != true {
                        labelStore.toggle(label, on: item)
                    }
                    labelingItem = nil
                }
                Button("Cancel", role: .cancel) { labelingItem = nil }
            }
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

    @ViewBuilder private var expiryWarning: some View {
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
    }

    private func continueWatchingSection(_ items: [DownloadItem]) -> some View {
        Section("Continue Watching") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            Button { start(item, at: item.playbackPosition ?? 0) } label: {
                                VideoThumbnailView(item: item, width: 174, height: 98)
                            }
                            .buttonStyle(.plain)
                            HStack(alignment: .top, spacing: 4) {
                                Text(item.displayTitle).font(.subheadline.bold()).lineLimit(2)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Menu { actions(for: item) } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .accessibilityLabel("More options for \(item.title)")
                                }
                            }
                            Text(item.downloadedText).font(.caption2).foregroundStyle(.secondary)
                            Label((item.playbackPosition ?? 0) > 10 ? "Resume" : "Next Episode",
                                  systemImage: (item.playbackPosition ?? 0) > 10 ? "play.fill" : "forward.end.fill")
                                .font(.caption).foregroundStyle(.tint)
                        }
                        .frame(width: 174, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Suggested shows to confirm, then the viewer's shows.
    @ViewBuilder private var showsSection: some View {
        let suggestions = ShowSuggestion.suggestions(items: completed, shows: shows, dismissed: showStore.dismissed)
        if !shows.isEmpty || !suggestions.isEmpty {
            Section("Shows") {
                ForEach(suggestions) { suggestion in
                    ShowSuggestionRow(suggestion: suggestion, accept: { accept(suggestion) }, dismiss: { showStore.dismissSuggestion(suggestion) })
                }
                ForEach(shows) { show in
                    let episodes = ShowPlaylist.episodes(of: show.id, in: completed)
                    // A row button and a separate Play button, like video rows: a button inside a
                    // navigation link takes the link's taps on iOS 18.
                    HStack(spacing: 4) {
                        Button { openedShow = show } label: { ShowRow(show: show, episodes: episodes) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("library.show")
                        if let next = ShowPlaylist.upNext(in: episodes) {
                            Button { start(next, at: next.isWatched ? 0 : next.playbackPosition ?? 0) } label: {
                                Image(systemName: "play.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play \(show.title)")
                        }
                    }
                }
            }
        }
    }

    private func accept(_ suggestion: ShowSuggestion.Suggestion) {
        if let show = suggestion.existingShow {
            showStore.add(suggestion.items, to: show)
        } else {
            newShowSeed = NewShowSeed(title: suggestion.series, selected: Set(suggestion.items.map(\.id)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(playableCompletedCount == 0 ? "Your library is empty" : "No matching videos", systemImage: "play.rectangle",
                                   description: Text(playableCompletedCount == 0 ? "Completed downloads play here, even offline." : "Try another search, filter or folder."))
            if playableCompletedCount == 0 {
                Button { showBrowse() } label: { Label("Find a video", systemImage: "safari") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func allVideosSection(_ displayed: [DownloadItem], labelsByID: [UUID: VideoLabel]) -> some View {
        Section(displayed.isEmpty ? "" : "All Videos") {
            ForEach(displayed) { item in
                HStack(spacing: 4) {
                    Button { open(item) } label: { LibraryRow(item: item, labels: item.labelIDs?.compactMap { labelsByID[$0] } ?? []) }
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
                .swipeActions(edge: .leading) {
                    Button(item.isWatched ? "Unwatched" : "Watched", systemImage: item.isWatched ? "circle" : "checkmark.circle") {
                        setWatched(item, !item.isWatched)
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) { downloads.delete(item) }
                    Button("Rename") { beginRename(item) }.tint(.blue)
                }
            }
        }
    }

    private func sortAndFilterMenu(_ query: LibraryQuery) -> some View {
        Menu {
            Section("Sort By") {
                ForEach(LibraryQuery.Sort.allCases) { sort in
                    Button { sortRaw = sort.rawValue } label: { checkmarked(sort.name, query.sort == sort) }
                }
            }
            Section("Show") {
                ForEach(LibraryQuery.Status.allCases) { status in
                    Button { statusRaw = status.rawValue } label: { checkmarked(status.name, query.status == status) }
                }
            }
            if !allLabels.isEmpty {
                Section("Labels") {
                    ForEach(allLabels) { label in
                        let on = query.labelIDs.contains(label.id)
                        Button { setLabelFilter(label.id, !on) } label: { checkmarked(label.name, on) }
                    }
                }
            }
            if query.isFiltering {
                Button("Clear Filters", systemImage: "xmark.circle", role: .destructive, action: clearFilters)
            }
        } label: {
            Label("Sort & Filter", systemImage: query.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("library.sortFilter")
    }

    @ViewBuilder private func checkmarked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// What is narrowing the list, each removable on its own.
    private func filterChips(_ query: LibraryQuery) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let folderID = query.folderID, let folder = folders.first(where: { $0.id == folderID }) {
                    FilterChip(title: folder.title, systemImage: "folder", color: .cyan) { selectedFolderID = nil }
                }
                if query.status != .all {
                    FilterChip(title: query.status.name, systemImage: "eye", color: .cyan) { statusRaw = LibraryQuery.Status.all.rawValue }
                }
                ForEach(allLabels.filter { query.labelIDs.contains($0.id) }) { label in
                    FilterChip(title: label.name, systemImage: "tag", color: label.color) { setLabelFilter(label.id, false) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func clearFilters() {
        statusRaw = LibraryQuery.Status.all.rawValue
        labelFilterRaw = ""
    }

    @ViewBuilder private func actions(for item: DownloadItem) -> some View {
        Button { setWatched(item, !item.isWatched) } label: {
            Label(item.isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: item.isWatched ? "circle" : "checkmark.circle")
        }
        Button { beginRename(item) } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            ForEach(allLabels) { label in
                Button { labelStore.toggle(label, on: item) } label: {
                    if item.labelIDs?.contains(label.id) == true { Label(label.name, systemImage: "checkmark") } else { Text(label.name) }
                }
            }
            Divider()
            Button("New Label…", systemImage: "plus") { newLabelName = ""; labelingItem = item }
        } label: { Label("Labels", systemImage: "tag") }
        Menu {
            ForEach(shows.filter { $0.id != item.showID }) { show in
                Button(show.title) { showStore.add([item], to: show) }
            }
            if !shows.isEmpty { Divider() }
            Button("New Show…", systemImage: "plus") { newShowSeed = .around(item, in: completed) }
        } label: { Label(item.showID == nil ? "Add to Show" : "Move to Show", systemImage: "rectangle.stack.badge.plus") }
        if item.showID != nil {
            Button { showStore.remove(item) } label: { Label("Remove from Show", systemImage: "rectangle.stack.badge.minus") }
        }
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

    private func setWatched(_ item: DownloadItem, _ watched: Bool) {
        item.setWatched(watched)
        try? modelContext.save()
    }

    /// Backups hold the library's records, not the videos themselves.
    private func restore(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let summary = try LibraryBackup.decode(Data(contentsOf: url)).restore(into: modelContext)
            restoreMessage = summary.text
        } catch {
            restoreMessage = "That file isn't a Video Downloader library backup."
        }
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

private struct FilterChip: View {
    let title: String
    let systemImage: String
    let color: Color
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption2)
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(title)")
    }
}

private struct LibraryRow: View {
    let item: DownloadItem
    let labels: [VideoLabel]
    @State private var duration: Double?

    var body: some View {
        let fileExists = fileExists
        HStack(spacing: 12) {
            VideoThumbnailView(item: item, width: 112, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                // Middle truncation keeps the episode number at the end of long series titles visible.
                Text(item.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
                // Date and size on their own lines: together they always wrap mid-way at this width.
                Text(item.downloadedText).font(.caption).foregroundStyle(.secondary)
                if !fileExists {
                    Text("File missing").font(.caption).foregroundStyle(.red)
                } else if let size = item.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                LabelChips(labels: labels)
                if item.isWatched {
                    Label("Watched", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else if (item.playbackPosition ?? 0) > 10 {
                    Label("Continue watching", systemImage: "play.circle.fill")
                        .font(.caption2).foregroundStyle(.tint)
                    if let duration = item.duration ?? duration, duration > 0 {
                        ProgressView(value: min((item.playbackPosition ?? 0) / duration, 1))
                            .tint(.cyan)
                            .accessibilityLabel("Playback progress")
                    }
                }
            }
        }
        .task(id: item.localFileName) {
            // Videos played before durations were recorded measure the file instead.
            guard item.duration == nil, let url = item.localURL, let fileName = item.localFileName, (item.playbackPosition ?? 0) > 10 else { return }
            duration = await ThumbnailCache.shared.duration(of: url, fileName: fileName)
        }
    }

    private var fileExists: Bool { item.localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
}

struct VideoThumbnailView: View {
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
        .overlay(alignment: .topTrailing) {
            if item.isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white, .green)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.localFileName) {
            // The body falls back to the in-memory cache, so clearing this doesn't flash a placeholder.
            image = nil
            image = await ThumbnailCache.shared.image(for: item.id, fileName: item.localFileName, mediaURL: item.localURL, kind: item.kind)
        }
    }
}
