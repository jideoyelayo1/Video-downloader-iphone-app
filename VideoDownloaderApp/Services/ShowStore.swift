import Foundation
import SwiftData

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

    @discardableResult
    func create(title: String, with items: [DownloadItem]) -> Show {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let show = Show(title: trimmed.isEmpty ? "Untitled Show" : trimmed)
        context.insert(show)
        for (index, item) in items.enumerated() {
            item.showID = show.id
            item.showOrder = index
            item.isMovie = false
        }
        updateFollowedPage(show)
        save()
        return show
    }

    /// Videos move out of any other show they were in.
    func add(_ items: [DownloadItem], to show: Show) {
        let current = episodes(of: show)
        let ids = Set(current.map(\.id))
        let newcomers = ShowSuggestion.inEpisodeOrder(items.filter { !ids.contains($0.id) })
        var order = (current.compactMap(\.showOrder).max() ?? -1) + 1
        for item in newcomers {
            item.showID = show.id
            item.showOrder = order
            item.isMovie = false
            order += 1
        }
        updateFollowedPage(show)
        save()
    }

    @discardableResult
    func addToMatchingShow(_ item: DownloadItem) -> Show? {
        guard item.showID == nil, !item.isMovie else { return nil }
        let parsed = ShowSuggestion.parse(item.displayTitle)
        guard parsed.episode != nil else { return nil }
        let all = videos()
        let show = shows.first { show in
            ShowSuggestion.Parsed(series: show.title, season: nil, episode: nil).key == parsed.key
                || ShowPlaylist.episodes(of: show.id, in: all).contains { ShowSuggestion.parse($0.displayTitle).key == parsed.key }
        }
        if let show { add([item], to: show) }
        return show
    }

    /// Unnumbered episodes don't count, so an older download can't send the checker back an episode.
    private func updateFollowedPage(_ show: Show) {
        show.followSourceURL = Self.latestEpisodePage(in: episodes(of: show))
    }

    static func latestEpisodePage(in episodes: [DownloadItem]) -> URL? {
        let numbered = episodes.compactMap { item -> (Int, URL)? in
            guard let number = EpisodeURL.number(in: item.sourcePageURL) ?? ShowSuggestion.parse(item.displayTitle).episode else { return nil }
            return (number, item.sourcePageURL)
        }
        return numbered.max { $0.0 < $1.0 }?.1
    }

    /// Shows made before new-episode checks existed have no followed page yet.
    func fillMissingFollowedPages() {
        var changed = false
        for show in shows where show.followSourceURL == nil {
            if let page = Self.latestEpisodePage(in: episodes(of: show)) {
                show.followSourceURL = page
                changed = true
            }
        }
        if changed { save() }
    }

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
        updateFollowedPage(show)
    }

    /// A movie isn't an episode, so marking one takes it out of its show.
    func setMovie(_ item: DownloadItem, _ movie: Bool) {
        if movie, item.showID != nil { remove(item) }
        item.isMovie = movie
        save()
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

    func delete(_ show: Show) {
        for item in episodes(of: show) {
            item.showID = nil
            item.showOrder = nil
        }
        context.delete(show)
        save()
    }

    /// Call before deleting a watched episode, so Continue Watching can find the next; the caller saves.
    func episodeDeleted(_ item: DownloadItem) {
        guard item.isWatched, let played = item.lastPlayedAt, let show = show(for: item) else { return }
        if show.deletedEpisodePlayedAt.map({ $0 < played }) ?? true { show.deletedEpisodePlayedAt = played }
    }

    func show(for item: DownloadItem) -> Show? {
        guard let showID = item.showID else { return nil }
        return shows.first { $0.id == showID }
    }

    func episode(_ offset: Int, from item: DownloadItem) -> DownloadItem? {
        guard let showID = item.showID else { return nil }
        let episodes = ShowPlaylist.episodes(of: showID, in: videos())
        guard let index = episodes.firstIndex(where: { $0.id == item.id }), episodes.indices.contains(index + offset) else { return nil }
        let episode = episodes[index + offset]
        guard let url = episode.localURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return episode
    }

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
