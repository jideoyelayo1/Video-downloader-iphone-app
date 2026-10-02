import Foundation
import SwiftData

/// Creates shows and keeps their episodes in the viewer's watch order (`DownloadItem.showOrder`).
@MainActor
final class ShowStore: ObservableObject {
    private static let dismissedKey = "dismissedShowSuggestions"

    private let context: ModelContext
    private let preferences: UserDefaults

    init(context: ModelContext, preferences: UserDefaults = .standard) {
        self.context = context
        self.preferences = preferences
    }

    var shows: [Show] {
        ((try? context.fetch(FetchDescriptor<Show>())) ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func episodes(of show: Show) -> [DownloadItem] { ShowPlaylist.episodes(of: show.id, in: videos()) }

    /// A new show with these videos in the given order.
    @discardableResult
    func create(title: String, with items: [DownloadItem]) -> Show {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let show = Show(title: trimmed.isEmpty ? "Untitled Show" : trimmed)
        context.insert(show)
        for (index, item) in items.enumerated() {
            item.showID = show.id
            item.showOrder = index
        }
        save()
        return show
    }

    /// Adds videos after the show's last episode, in episode order. Videos move out of any other show.
    func add(_ items: [DownloadItem], to show: Show) {
        let current = episodes(of: show)
        let ids = Set(current.map(\.id))
        let newcomers = ShowSuggestion.inEpisodeOrder(items.filter { !ids.contains($0.id) })
        var order = (current.compactMap(\.showOrder).max() ?? -1) + 1
        for item in newcomers {
            item.showID = show.id
            item.showOrder = order
            order += 1
        }
        save()
    }

    /// Takes the video out of its show; the video stays in the library.
    func remove(_ item: DownloadItem) {
        guard let showID = item.showID, let show = shows.first(where: { $0.id == showID }) else {
            item.showID = nil
            item.showOrder = nil
            save()
            return
        }
        item.showID = nil
        item.showOrder = nil
        renumber(episodes(of: show))
    }

    func move(in show: Show, from source: IndexSet, to destination: Int) {
        var ordered = episodes(of: show)
        ordered.move(fromOffsets: source, toOffset: destination)
        renumber(ordered)
    }

    func orderByEpisodeNumber(_ show: Show) { renumber(ShowSuggestion.inEpisodeOrder(episodes(of: show))) }

    func setAllWatched(_ show: Show, _ watched: Bool) {
        for item in episodes(of: show) { item.setWatched(watched) }
        save()
    }

    /// Deletes the show; its videos stay in the library.
    func delete(_ show: Show) {
        for item in episodes(of: show) {
            item.showID = nil
            item.showOrder = nil
        }
        context.delete(show)
        save()
    }

    /// The episode after this one when its show plays on automatically and the file is still there.
    func autoplayNext(after item: DownloadItem) -> DownloadItem? {
        guard let showID = item.showID, let show = shows.first(where: { $0.id == showID }), show.autoplayNext else { return nil }
        let episodes = ShowPlaylist.episodes(of: showID, in: videos())
        guard let next = ShowPlaylist.next(after: item, in: episodes),
              let url = next.localURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return next
    }

    // MARK: Suggestions

    var suggestions: [ShowSuggestion.Suggestion] {
        ShowSuggestion.suggestions(items: videos(), shows: shows, dismissed: dismissed)
    }

    func dismissSuggestion(_ suggestion: ShowSuggestion.Suggestion) {
        objectWillChange.send()
        preferences.set(Array(dismissed.union([suggestion.key])).sorted(), forKey: Self.dismissedKey)
    }

    var dismissed: Set<String> { Set(preferences.stringArray(forKey: Self.dismissedKey) ?? []) }

    func save() {
        objectWillChange.send()
        try? context.save()
    }

    private func renumber(_ ordered: [DownloadItem]) {
        for (index, item) in ordered.enumerated() { item.showOrder = index }
        save()
    }

    private func videos() -> [DownloadItem] { (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? [] }
}
