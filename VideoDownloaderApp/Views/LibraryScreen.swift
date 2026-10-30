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
    private var queriedCompleted: [DownloadItem]
    /// A video deleted from a show's page can still be in the query for one more render; reading it then crashes.
    private var completed: [DownloadItem] { queriedCompleted.filter { !$0.isDeleted && $0.modelContext != nil } }
    @Query(sort: \DownloadFolder.title) private var folders: [DownloadFolder]
    @Query(sort: \VideoLabel.name) private var allLabels: [VideoLabel]
    @Query(sort: \Show.title) private var shows: [Show]
    @Environment(\.modelContext) private var modelContext
    @State private var pendingPlayback: DownloadItem?
    @State private var renaming: DownloadItem?
    @State private var newTitle = ""
    @State private var searchText = ""
    @State private var selectedFolderID: UUID?
    @State private var group = LibraryQuery.Group.all
    @State private var showingNewFolder = false
    @State private var showingManageFolders = false
    @State private var newFolderTitle = ""
    @State private var expiryWarningDismissed = false
    @State private var showingManageLabels = false
    @State private var labelingItem: DownloadItem?
    @State private var newLabelName = ""
    @State private var newShowSeed: NewShowSeed?
    @State private var openedShow: Show?
    @State private var deletingShow: Show?
    @State private var deletingVideo: DownloadItem?
    /// Select mode: tapping a video ticks it, for the actions in the bar at the bottom.
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmingBulkDelete = false
    @State private var importingBackup = false
    @State private var restoreMessage: String?
    /// Thumbnail cards grow with the text size, so their titles still fit.
    @ScaledMetric(relativeTo: .footnote) private var cardWidth: CGFloat = 174
    @AppStorage("librarySort", store: AppServices.shared.preferences) private var sortRaw = LibraryQuery.Sort.newest.rawValue
    @AppStorage("libraryStatus", store: AppServices.shared.preferences) private var statusRaw = LibraryQuery.Status.all.rawValue
    @AppStorage("libraryLabels", store: AppServices.shared.preferences) private var labelFilterRaw = ""

    private var query: LibraryQuery {
        // Labels deleted since they were chosen drop out of the filter.
        let existing = Set(allLabels.map(\.id))
        return LibraryQuery(sort: LibraryQuery.Sort(rawValue: sortRaw) ?? .newest,
                            status: LibraryQuery.Status(rawValue: statusRaw) ?? .all, group: group,
                            showIDs: Set(shows.map(\.id)), labelIDs: labelFilter.intersection(existing),
                            folderID: selectedFolderID, searchText: searchText,
                            names: searchText.isEmpty ? [:] : Dictionary(shows.map { ($0.id, $0.title) } + allLabels.map { ($0.id, $0.name) },
                                                                         uniquingKeysWith: { first, _ in first }))
    }

    private var labelFilter: Set<UUID> { Set(labelFilterRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }

    private func setLabelFilter(_ id: UUID, _ on: Bool) {
        var ids = labelFilter
        if on { ids.insert(id) } else { ids.remove(id) }
        labelFilterRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    private var playableCompletedCount: Int { completed.filter { !$0.isStreamFragment }.count }
    /// Started but not finished, most recently played first.
    private var continueWatching: [DownloadItem] { ShowPlaylist.continueWatching(completed, shows: shows) }

    var body: some View {
        // Each list is filtered once per render instead of once per use.
        let query = query
        let displayed = query.apply(to: completed)
        let continueWatching = continueWatching
        let home = selectedFolderID == nil && searchText.isEmpty && !query.isFiltering && !selecting
        let labelsByID = Dictionary(allLabels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                expiryWarning
                if home, let hero = continueWatching.first {
                    heroSection(hero)
                }
                // The hero already shows the first one.
                if home && continueWatching.count > 1 {
                    continueWatchingSection(Array(continueWatching.dropFirst()))
                }
                if home { showsSection }
                if home { moviesSection }
                if displayed.isEmpty { emptyState(query) }
                allVideosSection(displayed, title: query.group.name, labelsByID: labelsByID)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            // Outside the list: on iOS 18 a list row swallows taps on buttons in a scroll view.
            .safeAreaInset(edge: .top, spacing: 0) {
                if query.isFiltering || selectedFolderID != nil { filterChips(query) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectionBar(displayed) }
            }
            .navigationTitle("My Videos")
            .searchable(text: $searchText, prompt: "Search videos")
            .onChange(of: folders.map(\.id)) { _, ids in
                if let selectedFolderID, !ids.contains(selectedFolderID) { self.selectedFolderID = nil }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting || !displayed.isEmpty {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            selection = []
                        }
                        .accessibilityIdentifier("library.select")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { sortAndFilterMenu(query) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All Videos") { selectedFolderID = nil; group = .all }
                        ForEach([LibraryQuery.Group.movies, .notInShow]) { place in
                            Button(place.name, systemImage: place.systemImage) { group = place }
                        }
                        if !folders.isEmpty { Divider() }
                        ForEach(folders) { folder in
                            Button(folder.title) { selectedFolderID = folder.id }
                        }
                        Divider()
                        Button("New Folder", systemImage: "folder.badge.plus") { newFolderTitle = ""; showingNewFolder = true }
                        Button("Manage Folders", systemImage: "folder") { showingManageFolders = true }
                        Button("Manage Labels", systemImage: "tag") { showingManageLabels = true }
                        Divider()
                        ShareLink(item: LibraryBackupFile { [container = modelContext.container] in LibraryBackup.make(from: container.mainContext) },
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
            .modifier(DeleteShowDialog(show: $deletingShow))
            .modifier(DeleteVideoAlert(item: $deletingVideo))
            .alert(selection.count == 1 ? "Delete 1 video?" : "Delete \(selection.count) videos?", isPresented: $confirmingBulkDelete) {
                Button("Delete", role: .destructive) {
                    downloads.delete(selectedItems)
                    selection = []
                    selecting = false
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This frees \(StorageCleanup.sizeText(selectedItems)) on this iPhone.") }
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

    /// Netflix's billboard: the video you'd carry on with, full width, with Play and Episodes.
    private func heroSection(_ item: DownloadItem) -> some View {
        let show = shows.first { $0.id == item.showID }
        let resuming = (item.playbackPosition ?? 0) > 10
        return Section {
            ZStack(alignment: .bottom) {
                VideoThumbnailView(item: item, width: nil, height: 200, cornerRadius: 0, showsWatchedBadge: false)
                LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: .center, endPoint: .bottom)
                VStack(spacing: 8) {
                    Text(show?.title ?? item.displayTitle)
                        .font(.title.weight(.heavy)).multilineTextAlignment(.center).lineLimit(2)
                    Text(heroDetail(item, in: show)).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    HStack(spacing: 10) {
                        Button { start(item, at: resuming ? item.playbackPosition ?? 0 : 0) } label: {
                            Label("Play", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                        .accessibilityIdentifier("library.hero.play")
                        if let show {
                            Button { openedShow = show } label: {
                                Label("Episodes", systemImage: "list.bullet").font(.headline).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.white)
                        }
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 14)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.black)
        }
    }

    private func heroDetail(_ item: DownloadItem, in show: Show?) -> String {
        var parts: [String] = []
        if show != nil { parts.append(item.displayTitle) }
        if let duration = item.duration, duration > 0, (item.playbackPosition ?? 0) > 10 {
            let left = max(duration - (item.playbackPosition ?? 0), 0)
            parts.append(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left")
        } else if let show {
            parts.append(show.title == item.displayTitle ? "Next episode" : "Up next")
        }
        return parts.joined(separator: " · ")
    }

    /// Netflix-style section titles: bold and white, not small caps.
    private func rowHeader(_ title: String) -> some View {
        Text(title).font(.title3.bold()).foregroundStyle(.white).textCase(nil)
    }

    private func continueWatchingSection(_ items: [DownloadItem]) -> some View {
        cardRow(items, caption: { ($0.playbackPosition ?? 0) > 10 ? "Resume" : "Next Episode" },
                play: { start($0, at: $0.playbackPosition ?? 0) }) { rowHeader("Continue Watching") }
    }

    /// Movies side by side, like Continue Watching; See All lists them with search and sort.
    @ViewBuilder private var moviesSection: some View {
        let movies = completed.filter { $0.isMovie && !$0.isStreamFragment }
        if !movies.isEmpty {
            // See All lists the rest.
            cardRow(Array(movies.prefix(20)), caption: movieCaption, play: open) {
                HStack {
                    rowHeader("Movies")
                    Spacer()
                    Button("See All") { group = .movies }.font(.subheadline).textCase(nil)
                        .accessibilityIdentifier("library.movies.seeAll")
                }
            }
        }
    }

    private func movieCaption(_ item: DownloadItem) -> String {
        if item.isWatched { return "Watched" }
        if (item.playbackPosition ?? 0) > 10 { return "Resume" }
        if let duration = item.duration, duration > 0 { return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) }
        return item.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    /// Netflix's row of thumbnails, each with its title, a menu and a caption.
    private func cardRow<Header: View>(_ items: [DownloadItem], caption: @escaping (DownloadItem) -> String,
                                       play: @escaping (DownloadItem) -> Void, @ViewBuilder header: () -> Header) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { play(item) } label: {
                                VideoThumbnailView(item: item, width: cardWidth, height: cardWidth * 98 / 174, showsWatchedBadge: false)
                                    .overlay {
                                        Image(systemName: "play.circle")
                                            .font(.system(size: 38, weight: .light)).foregroundStyle(.white)
                                            .shadow(radius: 4)
                                    }
                                    .overlay(alignment: .bottom) { PlaybackProgressBar(item: item) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play \(item.displayTitle)")
                            HStack(alignment: .top, spacing: 4) {
                                Text(item.displayTitle).font(.footnote.bold()).lineLimit(2)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Menu { actions(for: item) } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(minWidth: 24, minHeight: 20)
                                        .accessibilityLabel("More options for \(item.title)")
                                }
                            }
                            Text(caption(item))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: cardWidth, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.black)
        } header: { header() }
    }

    /// Suggested shows to confirm, the viewer's shows, then the videos still to sort.
    @ViewBuilder private var showsSection: some View {
        let suggestions = ShowSuggestion.suggestions(items: completed, shows: shows, dismissed: showStore.dismissed)
        if !shows.isEmpty || !suggestions.isEmpty {
            Section {
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
                    .contextMenu {
                        Button("Delete Show…", systemImage: "trash", role: .destructive) { deletingShow = show }
                    }
                    .swipeActions(edge: .trailing) {
                        // Not a destructive role: the row stays until the dialog's answer.
                        Button("Delete", systemImage: "trash") { deletingShow = show }.tint(.red)
                    }
                }
                let loose = completed.filter(LibraryQuery(group: .notInShow, showIDs: Set(shows.map(\.id))).matches).count
                if loose > 0 {
                    Button { group = .notInShow } label: {
                        HStack {
                            Label(loose == 1 ? "1 video isn't in a show" : "\(loose) videos aren't in a show",
                                  systemImage: LibraryQuery.Group.notInShow.systemImage)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.notInShow")
                }
            } header: { rowHeader("My Shows") }
        }
    }

    private func accept(_ suggestion: ShowSuggestion.Suggestion) {
        if let show = suggestion.existingShow {
            showStore.add(suggestion.items, to: show)
        } else {
            newShowSeed = NewShowSeed(title: suggestion.series, selected: Set(suggestion.items.map(\.id)))
        }
    }

    private func emptyState(_ query: LibraryQuery) -> some View {
        // Movies or Not in a Show is empty on its own, not just with the other filters.
        let placeIsEmpty = !completed.contains(where: LibraryQuery(group: query.group, showIDs: query.showIDs).matches)
        let (title, detail): (String, String) = switch (playableCompletedCount, query.group, placeIsEmpty) {
        case (0, _, _): ("Your library is empty", "Completed downloads play here, even offline.")
        case (_, .movies, true): ("No movies yet", "Choose Mark as Movie in a video's menu to put it here.")
        case (_, .notInShow, true): ("Every video is sorted", "Each one is in a show or under Movies.")
        default: ("No matching videos", "Try another search, filter or folder.")
        }
        return VStack(spacing: 14) {
            ContentUnavailableView(title, systemImage: query.group.systemImage, description: Text(detail))
            if playableCompletedCount == 0 {
                Button { showBrowse() } label: { Label("Find a video", systemImage: "safari") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func allVideosSection(_ displayed: [DownloadItem], title: String, labelsByID: [UUID: VideoLabel]) -> some View {
        Section {
            ForEach(displayed) { item in
                // SwiftUI can rebuild a row from the old list after its video was deleted (from a show's page).
                if !item.isDeleted, item.modelContext != nil {
                    HStack(spacing: 4) {
                        let selected = selection.contains(item.id)
                        Button { selecting ? toggleSelection(item) : open(item) } label: {
                            HStack(spacing: 10) {
                                if selecting {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(selected ? Color.brandRed : .secondary)
                                        .accessibilityHidden(true)
                                }
                                LibraryRow(item: item, labels: item.labelIDs?.compactMap { labelsByID[$0] } ?? [])
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(selecting && selected ? .isSelected : [])
                        .accessibilityIdentifier("library.item")
                        if !selecting {
                            Menu { actions(for: item) } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .frame(minWidth: 40, minHeight: 44)
                                    .accessibilityLabel("More options for \(item.title)")
                            }
                            .accessibilityIdentifier("library.moreOptions")
                        }
                    }
                    .contextMenu { actions(for: item) }
                    .swipeActions(edge: .leading) {
                        Button(item.isWatched ? "Unwatched" : "Watched", systemImage: item.isWatched ? "circle" : "checkmark.circle") {
                            setWatched(item, !item.isWatched)
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        // Not .destructive: that removes the row before the alert is answered.
                        Button("Delete") { deletingVideo = item }.tint(.red)
                        Button("Rename") { beginRename(item) }.tint(.blue)
                    }
                }
            }
        } header: { if !displayed.isEmpty { rowHeader(title) } }
    }

    private var selectedItems: [DownloadItem] { completed.filter { selection.contains($0.id) } }

    private func toggleSelection(_ item: DownloadItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// The actions for the ticked videos, over the tab bar.
    private func selectionBar(_ displayed: [DownloadItem]) -> some View {
        let items = selectedItems
        let allSelected = !displayed.isEmpty && displayed.allSatisfy { selection.contains($0.id) }
        return HStack(spacing: 18) {
            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(displayed.map(\.id))
            }
            Spacer()
            Menu {
                Button("Mark as Watched", systemImage: "checkmark.circle") { items.forEach { $0.setWatched(true) }; try? modelContext.save() }
                Button("Mark as Unwatched", systemImage: "circle") { items.forEach { $0.setWatched(false) }; try? modelContext.save() }
                Button("Mark as Movies", systemImage: "film") { items.forEach { showStore.setMovie($0, true) } }
                Button("Not Movies", systemImage: "film.stack") { items.forEach { showStore.setMovie($0, false) } }
                Menu("Add to Show", systemImage: "rectangle.stack.badge.plus") {
                    ForEach(shows) { show in Button(show.title) { showStore.add(items, to: show) } }
                    Button("New Show…", systemImage: "plus") {
                        newShowSeed = NewShowSeed(title: items.first.map { ShowSuggestion.parse($0.displayTitle).series } ?? "", selected: selection)
                    }
                }
                Menu("Move to Folder", systemImage: "folder") {
                    Button("No Folder") { items.forEach { $0.folderID = nil }; try? modelContext.save() }
                    ForEach(folders) { folder in
                        Button(folder.title) { items.forEach { $0.folderID = folder.id }; try? modelContext.save() }
                    }
                }
            } label: { Label("Actions", systemImage: "ellipsis.circle") }
            .disabled(items.isEmpty)
            Button(role: .destructive) { confirmingBulkDelete = true } label: { Label("Delete", systemImage: "trash") }
                .disabled(items.isEmpty)
                .accessibilityIdentifier("library.deleteSelected")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
                if query.group != .all {
                    FilterChip(title: query.group.name, systemImage: query.group.systemImage, color: .brandRed) { group = .all }
                }
                if let folderID = query.folderID, let folder = folders.first(where: { $0.id == folderID }) {
                    FilterChip(title: folder.title, systemImage: "folder", color: .brandRed) { selectedFolderID = nil }
                }
                if query.status != .all {
                    FilterChip(title: query.status.name, systemImage: "eye", color: .brandRed) { statusRaw = LibraryQuery.Status.all.rawValue }
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
        group = .all
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
        Button { showStore.setMovie(item, !item.isMovie) } label: {
            Label(item.isMovie ? "Not a Movie" : "Mark as Movie", systemImage: item.isMovie ? "film.stack" : "film")
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
        Button(role: .destructive) { deletingVideo = item } label: { Label("Delete…", systemImage: "trash") }
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
        } catch let error as LibraryBackup.RestoreError {
            restoreMessage = error.localizedDescription
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
                            .tint(.brandRed)
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

/// Netflix's thin red bar along the bottom of a thumbnail, for a video started but not finished.
struct PlaybackProgressBar: View {
    let item: DownloadItem

    var body: some View {
        if let duration = item.duration, duration > 0, (item.playbackPosition ?? 0) > 10, !item.isWatched {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.3))
                    Rectangle().fill(Color.brandRed).frame(width: proxy.size.width * min((item.playbackPosition ?? 0) / duration, 1))
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }
}

struct VideoThumbnailView: View {
    let item: DownloadItem
    /// nil stretches to the available width, for the hero image.
    var width: CGFloat? = 72
    var height: CGFloat = 48
    var cornerRadius: CGFloat = 6
    var showsWatchedBadge = true
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                // Decorative: the row or card names the video.
                if let image = image ?? ThumbnailCache.shared.cachedImage(for: item.id, fileName: item.localFileName) {
                    Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                } else {
                    Image(systemName: "film").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsWatchedBadge && item.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white, .green)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: item.localFileName) {
                // The body falls back to the in-memory cache, so clearing this doesn't flash a placeholder.
                image = nil
                image = await ThumbnailCache.shared.image(for: item.id, fileName: item.localFileName, mediaURL: item.localURL, kind: item.kind)
            }
    }
}
