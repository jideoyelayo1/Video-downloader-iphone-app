import SwiftData
import SwiftUI

/// What the New Show sheet starts with: a suggested name and videos, or a show to add to.
struct NewShowSeed: Identifiable {
    let id = UUID()
    var title: String
    var selected: Set<UUID>
    var show: Show?

    /// The video's series name, with the other saved episodes of that series ticked.
    static func around(_ item: DownloadItem, in items: [DownloadItem]) -> NewShowSeed {
        let parsed = ShowSuggestion.parse(item.displayTitle)
        let matches = items.filter { $0.showID == nil && ShowSuggestion.parse($0.displayTitle).key == parsed.key }
        return NewShowSeed(title: parsed.series, selected: Set(matches.map(\.id) + [item.id]))
    }
}

/// A show in My Videos: the next episode's thumbnail and progress.
struct ShowRow: View {
    let show: Show
    let episodes: [DownloadItem]

    var body: some View {
        let next = ShowPlaylist.upNext(in: episodes)
        let watched = episodes.filter(\.isWatched).count
        HStack(spacing: 12) {
            if let next {
                VideoThumbnailView(item: next, width: 112, height: 72)
            } else {
                Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.tint)
                    .frame(width: 112, height: 72).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(show.title).font(.headline).lineLimit(2)
                Text("\(watched) of \(episodes.count) watched").font(.caption).foregroundStyle(.secondary)
                if let next, watched < episodes.count {
                    Text("Next: " + ShowScreen.episodeName(next, in: episodes)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// "13 videos look like a show" with Create Show (or Add, for a show that exists) and Not Now.
struct ShowSuggestionRow: View {
    let suggestion: ShowSuggestion.Suggestion
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles.tv").font(.title2).foregroundStyle(.tint).frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                if let show = suggestion.existingShow {
                    Text("\(suggestion.items.count) new \(suggestion.items.count == 1 ? "episode" : "episodes") of \(show.title)")
                        .font(.subheadline.bold())
                } else {
                    Text("\(suggestion.items.count) videos look like a show").font(.subheadline.bold())
                    Text(suggestion.series).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button(suggestion.existingShow == nil ? "Create Show" : "Add to Show", action: accept)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Not Now", action: dismiss).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.showSuggestion")
    }
}

/// Names a show and picks its episodes; suggestions arrive with both filled in.
struct NewShowSheet: View {
    let seed: NewShowSeed
    @EnvironmentObject private var shows: ShowStore
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<DownloadItem> { $0.statusRaw == "completed" }) private var items: [DownloadItem]
    @State private var title = ""
    @State private var selected: Set<UUID> = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if seed.show == nil {
                    Section("Name") {
                        TextField("Show name", text: $title)
                            .accessibilityIdentifier("newShow.name")
                    }
                }
                Section {
                    ForEach(listed) { item in
                        Button { toggle(item) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(selected.contains(item.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle).lineLimit(2).truncationMode(.middle).foregroundStyle(.primary)
                                    if item.showID != nil && item.showID != seed.show?.id {
                                        Text("Moves from another show").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
                    }
                } header: {
                    Text("\(selected.count) selected")
                } footer: {
                    Text("Episodes are added in episode order. You can change the order in the show.")
                }
            }
            .searchable(text: $searchText, prompt: "Search videos")
            .navigationTitle(seed.show == nil ? "New Show" : "Add to \(seed.show?.title ?? "Show")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(seed.show == nil ? "Create" : "Add", action: save).disabled(selected.isEmpty)
                }
            }
            .onAppear {
                title = seed.title
                selected = seed.selected
            }
        }
    }

    /// Ticked videos first, then the rest in natural title order; episodes of the show already in it are left out.
    private var listed: [DownloadItem] {
        items.filter { !$0.isStreamFragment && ($0.showID == nil || $0.showID != seed.show?.id) }
            .filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }
            .sorted { a, b in
                let ticked = (seed.selected.contains(a.id), seed.selected.contains(b.id))
                if ticked.0 != ticked.1 { return ticked.0 }
                return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
            }
    }

    private func toggle(_ item: DownloadItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func save() {
        let chosen = items.filter { selected.contains($0.id) }
        if let show = seed.show {
            shows.add(chosen, to: show)
        } else {
            shows.create(title: title, with: ShowSuggestion.inEpisodeOrder(chosen))
        }
        dismiss()
    }
}

/// A show's episodes in watch order: drag to reorder, play the next one, and choose whether
/// episodes play on one after another.
struct ShowScreen: View {
    @Bindable var show: Show
    @EnvironmentObject private var shows: ShowStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<DownloadItem> { $0.statusRaw == "completed" }) private var items: [DownloadItem]
    @State private var confirmingDeleteWatched = false
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var addingVideos: NewShowSeed?
    @State private var deleting: Show?
    @State private var pendingPlayback: DownloadItem?
    @State private var checking = false

    var body: some View {
        let episodes = ShowPlaylist.episodes(of: show.id, in: items)
        let watched = episodes.filter(\.isWatched).count
        List {
            Section {
                if let next = ShowPlaylist.upNext(in: episodes) {
                    Button { play(next) } label: {
                        HStack(spacing: 12) {
                            VideoThumbnailView(item: next, width: 112, height: 63)
                            VStack(alignment: .leading, spacing: 3) {
                                Label(playLabel(next, all: episodes), systemImage: "play.fill").font(.headline).foregroundStyle(.tint)
                                Text(next.displayTitle).font(.caption).foregroundStyle(Color.secondary).lineLimit(2).truncationMode(.middle)
                            }
                        }
                    }
                    .accessibilityIdentifier("show.playNext")
                }
                Toggle("Autoplay Next Episode", isOn: Binding(get: { show.autoplayNext }, set: { show.autoplayNext = $0; shows.save() }))
                    .accessibilityIdentifier("show.autoplay")
            } footer: {
                Text("\(watched) of \(episodes.count) watched · \(StorageCleanup.sizeText(episodes))")
            }
            Section {
                Toggle("Tell Me When the Next Episode Is Out", isOn: Binding(get: { show.notifyNewEpisodes }, set: { on in
                    show.notifyNewEpisodes = on
                    shows.save()
                    if on { Task { _ = await NewEpisodeChecker.requestPermission() } }
                }))
                .accessibilityIdentifier("show.notify")
                Toggle("Download It Automatically", isOn: Binding(get: { show.autoDownloadNewEpisodes }, set: { show.autoDownloadNewEpisodes = $0; shows.save() }))
                    .accessibilityIdentifier("show.autoDownload")
                if show.notifyNewEpisodes || show.autoDownloadNewEpisodes {
                    Button(checking ? "Checking…" : "Check Now") {
                        checking = true
                        Task {
                            await AppServices.shared.newEpisodes.check(show)
                            checking = false
                        }
                    }
                    .disabled(checking || show.followSourceURL == nil)
                }
            } header: {
                Text("New Episodes")
            } footer: {
                Text(newEpisodesFooter)
            }
            Section("Episodes") {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, item in
                    Button { open(item) } label: { EpisodeRow(number: index + 1, item: item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("show.episode")
                        .swipeActions(edge: .leading) {
                            Button(item.isWatched ? "Unwatched" : "Watched", systemImage: item.isWatched ? "circle" : "checkmark.circle") {
                                item.setWatched(!item.isWatched)
                                shows.save()
                            }
                            .tint(.green)
                        }
                        .contextMenu {
                            Button(item.isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: item.isWatched ? "circle" : "checkmark.circle") {
                                item.setWatched(!item.isWatched)
                                shows.save()
                            }
                            Button("Remove from Show", systemImage: "rectangle.stack.badge.minus") { shows.remove(item) }
                        }
                }
                .onMove { shows.move(in: show, from: $0, to: $1) }
                .onDelete { offsets in offsets.map { episodes[$0] }.forEach(shows.remove) }
            }
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") { newTitle = show.title; renaming = true }
                    Button("Add Videos…", systemImage: "plus") { addingVideos = NewShowSeed(title: show.title, selected: [], show: show) }
                    Button("Order by Episode Number", systemImage: "list.number") { shows.orderByEpisodeNumber(show) }
                    Button("Mark All Watched", systemImage: "checkmark.circle") { shows.setAllWatched(show, true) }
                    Button("Mark All Unwatched", systemImage: "circle") { shows.setAllWatched(show, false) }
                    let watchedEpisodes = episodes.filter(\.isWatched)
                    if !watchedEpisodes.isEmpty {
                        Button("Delete Watched Episodes (\(watchedEpisodes.count), \(StorageCleanup.sizeText(watchedEpisodes)))",
                               systemImage: "trash.slash", role: .destructive) { confirmingDeleteWatched = true }
                    }
                    Divider()
                    Button("Delete Show…", systemImage: "trash", role: .destructive) { deleting = show }
                } label: { Label("Show options", systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("show.options")
            }
        }
        .sheet(item: $addingVideos) { NewShowSheet(seed: $0) }
        .alert("Rename show", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Save") {
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { show.title = trimmed; shows.save() }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Delete the watched episodes?", isPresented: $confirmingDeleteWatched, titleVisibility: .visible) {
            Button("Delete Watched Episodes", role: .destructive) {
                downloads.delete(ShowPlaylist.episodes(of: show.id, in: items).filter(\.isWatched))
            }
        } message: { Text("Their video files are removed from this iPhone. The show keeps the rest.") }
        // Leave first: the screen reads the show while it animates away.
        .modifier(DeleteShowDialog(show: $deleting, leave: { dismiss() }))
        .confirmationDialog("Play video", isPresented: Binding(get: { pendingPlayback != nil }, set: { if !$0 { pendingPlayback = nil } })) {
            Button("Resume") { if let item = pendingPlayback { start(item, at: item.playbackPosition ?? 0) }; pendingPlayback = nil }
            Button("Start from Beginning") { if let item = pendingPlayback { start(item, at: 0) }; pendingPlayback = nil }
        } message: { Text("Continue where you stopped or play from the beginning?") }
    }

    private var newEpisodesFooter: String {
        guard let page = show.followSourceURL, EpisodeURL.next(after: page) != nil else {
            return "Works for sites whose episode pages are numbered, such as ***REMOVED*** and ***REMOVED***."
        }
        let checked = show.lastCheckedAt.map { " Last checked " + $0.formatted(.relative(presentation: .named)) + "." } ?? ""
        return "Checks \(page.host ?? "the site") for the next episode when you open the app, and in the background now and then." + checked
    }

    /// "Ep. 10" when the title has an episode number, else the episode's place in the show.
    static func episodeName(_ item: DownloadItem, in episodes: [DownloadItem]) -> String {
        if let episode = ShowSuggestion.parse(item.displayTitle).episode { return "Ep. \(episode)" }
        return "Episode \((episodes.firstIndex { $0.id == item.id } ?? 0) + 1)"
    }

    private func playLabel(_ item: DownloadItem, all episodes: [DownloadItem]) -> String {
        let name = Self.episodeName(item, in: episodes)
        if !item.isWatched && (item.playbackPosition ?? 0) > 10 { return "Resume \(name)" }
        return "Play \(name)"
    }

    /// The Play button resumes where the viewer stopped.
    private func play(_ item: DownloadItem) {
        start(item, at: item.isWatched ? 0 : item.playbackPosition ?? 0)
    }

    private func open(_ item: DownloadItem) {
        if (item.playbackPosition ?? 0) > 10 { pendingPlayback = item } else { start(item, at: 0) }
    }

    private func start(_ item: DownloadItem, at position: Double) {
        if position == 0 { item.playbackPosition = 0; try? modelContext.save() }
        playback.open(item, at: position)
    }
}

/// Deletes a show with its episodes' videos, or leaves the videos in My Videos.
struct DeleteShowDialog: ViewModifier {
    @Binding var show: Show?
    /// Leaves a screen that shows the show, before it is deleted.
    var leave: (() -> Void)?
    @EnvironmentObject private var shows: ShowStore
    @EnvironmentObject private var downloads: DownloadManager

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete this show?", isPresented: Binding(get: { show != nil }, set: { if !$0 { show = nil } }),
                                   titleVisibility: .visible, presenting: show) { show in
            if !shows.episodes(of: show).isEmpty {
                Button("Delete Show and Episodes", role: .destructive) { delete(show, withEpisodes: true) }
            }
            Button("Delete Show Only", role: .destructive) { delete(show, withEpisodes: false) }
        } message: { show in
            let episodes = shows.episodes(of: show)
            if episodes.isEmpty {
                Text("It has no episodes.")
            } else {
                Text("Deleting its episodes removes \(episodes.count == 1 ? "1 video" : "\(episodes.count) videos") (\(StorageCleanup.sizeText(episodes))) from this iPhone. With Delete Show Only, they stay in My Videos.")
            }
        }
    }

    private func delete(_ show: Show, withEpisodes: Bool) {
        let delete = { withEpisodes ? downloads.deleteShowAndEpisodes(show) : shows.delete(show) }
        guard let leave else { return delete() }
        leave()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            delete()
        }
    }
}

private struct EpisodeRow: View {
    let number: Int
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.subheadline.monospacedDigit().bold()).foregroundStyle(.secondary).frame(minWidth: 22)
            VideoThumbnailView(item: item, width: 88, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.subheadline).foregroundStyle(.primary).lineLimit(2).truncationMode(.middle)
                if item.isWatched {
                    Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                } else if let duration = item.duration, duration > 0, (item.playbackPosition ?? 0) > 10 {
                    ProgressView(value: min((item.playbackPosition ?? 0) / duration, 1)).tint(.cyan)
                        .accessibilityLabel("Playback progress")
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
