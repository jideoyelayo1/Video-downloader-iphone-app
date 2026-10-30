import Foundation

/// Recognises episodes of one series from their titles, such as
/// "***REMOVED*** Ep. 3 · ***REMOVED***" or "Watch South Park (1997) S29E2 - Watch Series".
enum ShowSuggestion {
    struct Parsed: Equatable {
        let series: String
        let season: Int?
        let episode: Int?

        /// Groups titles that differ only in case or spacing.
        var key: String { series.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    struct Suggestion: Identifiable {
        let series: String
        let key: String
        /// In episode order.
        let items: [DownloadItem]
        /// A show with this name that these newer episodes could join.
        let existingShow: Show?
        var id: String { key }
    }

    private static let seasonEpisode = try! NSRegularExpression(pattern: #"\bS(\d{1,2})\s*E(\d{1,4})\b"#, options: .caseInsensitive)
    private static let episodeMarker = try! NSRegularExpression(pattern: #"\b(?:Ep\.?|Episode|E)\s*(\d{1,4})\b"#, options: .caseInsensitive)
    private static let trailingNumber = try! NSRegularExpression(pattern: #"\s(\d{1,3})\s*$"#)  // not years
    /// Words sites wrap around titles, such as My***REMOVED***' "Watch … - Watch Series".
    private static let noise = try! NSRegularExpression(pattern: #"^\s*watch\s+|\s+[-–|·]\s*watch (series|online|free).*$"#, options: .caseInsensitive)

    static func parse(_ title: String) -> Parsed {
        let cleaned = noise.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            Range(match.range(at: group), in: cleaned).flatMap { Int(cleaned[$0]) }
        }
        func series(before match: NSTextCheckingResult) -> String {
            let end = Range(match.range, in: cleaned)?.lowerBound ?? cleaned.endIndex
            return String(cleaned[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—·:|,#").union(.whitespaces))
        }
        if let match = seasonEpisode.matches(in: cleaned, range: range).last {
            let name = series(before: match)
            return Parsed(series: name.isEmpty ? cleaned : name, season: number(match, 1), episode: number(match, 2))
        }
        if let match = episodeMarker.matches(in: cleaned, range: range).last ?? trailingNumber.matches(in: cleaned, range: range).last {
            let name = series(before: match)
            if !name.isEmpty { return Parsed(series: name, season: nil, episode: number(match, 1)) }
        }
        return Parsed(series: cleaned.trimmingCharacters(in: .whitespaces), season: nil, episode: nil)
    }

    /// Episode order: season, then episode, then natural title order.
    static func inEpisodeOrder(_ items: [DownloadItem]) -> [DownloadItem] {
        items.map { ($0, parse($0.displayTitle)) }.sorted { a, b in
            let left = (a.1.season ?? 0, a.1.episode ?? Int.max), right = (b.1.season ?? 0, b.1.episode ?? Int.max)
            if left != right { return left < right }
            return a.0.displayTitle.localizedStandardCompare(b.0.displayTitle) == .orderedAscending
        }.map(\.0)
    }

    /// Two or more saved episodes of a series that isn't a show yet, or newer episodes of an
    /// existing show (matched by name). Dismissed suggestions and movies stay hidden.
    static func suggestions(items: [DownloadItem], shows: [Show], dismissed: Set<String>) -> [Suggestion] {
        let candidates = items.filter { $0.status == .completed && !$0.isStreamFragment && $0.showID == nil && !$0.isMovie }
        let parsed = candidates.map { ($0, parse($0.displayTitle)) }.filter { $0.1.episode != nil }
        let groups = Dictionary(grouping: parsed, by: \.1.key)
        let showsByKey = Dictionary(shows.map { (Parsed(series: $0.title, season: nil, episode: nil).key, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.compactMap { key, members -> Suggestion? in
            let existing = showsByKey[key]
            guard !dismissed.contains(key), members.count >= (existing == nil ? 2 : 1) else { return nil }
            return Suggestion(series: members[0].1.series, key: key, items: inEpisodeOrder(members.map(\.0)), existingShow: existing)
        }
        .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.series.localizedStandardCompare($1.series) == .orderedAscending }
    }
}

/// A show's episodes in the viewer's watch order.
enum ShowPlaylist {
    static func episodes(of showID: UUID, in items: [DownloadItem]) -> [DownloadItem] {
        items.filter { $0.showID == showID }.sorted { a, b in
            let left = a.showOrder ?? Int.max, right = b.showOrder ?? Int.max
            return left != right ? left < right : a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
        }
    }

    struct SeasonRun: Identifiable, Equatable {
        let season: Int?
        let range: Range<Int>
        var id: Int { range.lowerBound }
    }

    /// A show page's sections: one per season when every title names its season ("S2E3") and
    /// there's more than one, else one. Each is a run of the watch order, so moves stay within it.
    static func seasonRuns(_ episodes: [DownloadItem]) -> [SeasonRun] {
        var runs: [SeasonRun] = []
        for (index, item) in episodes.enumerated() {
            let season = ShowSuggestion.parse(item.title).season
            if let last = runs.last, last.season == season {
                runs[runs.count - 1] = SeasonRun(season: season, range: last.range.lowerBound..<index + 1)
            } else {
                runs.append(SeasonRun(season: season, range: index..<index + 1))
            }
        }
        guard runs.count > 1, runs.allSatisfy({ $0.season != nil }) else { return [SeasonRun(season: nil, range: episodes.indices)] }
        return runs
    }

    static func next(after item: DownloadItem, in episodes: [DownloadItem]) -> DownloadItem? {
        guard let index = episodes.firstIndex(where: { $0.id == item.id }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    /// Videos started but not finished, plus the next episode of each show whose most recently
    /// played episode was finished, even if that episode was deleted since; most recently played first.
    static func continueWatching(_ items: [DownloadItem], shows: [Show] = []) -> [DownloadItem] {
        let playable = items.filter { $0.status == .completed && !$0.isStreamFragment }
        var entries = playable.filter { !$0.isWatched && ($0.playbackPosition ?? 0) > 10 }
            .map { (item: $0, played: $0.lastPlayedAt ?? .distantPast, position: $0.playbackPosition ?? 0) }
        var included = Set(entries.map(\.item.id))
        let deletedPlays = Dictionary(shows.compactMap { show in show.deletedEpisodePlayedAt.map { (show.id, $0) } }, uniquingKeysWith: max)
        for showID in Set(playable.compactMap(\.showID)) {
            let ordered = episodes(of: showID, in: playable)
            let last = ordered.filter { $0.lastPlayedAt != nil }.max { $0.lastPlayedAt! < $1.lastPlayedAt! }
            let following: DownloadItem?, played: Date
            if let deleted = deletedPlays[showID], deleted > last?.lastPlayedAt ?? .distantPast {
                // The episode played last was deleted once watched; the first one not watched follows it.
                (following, played) = (ordered.first { !$0.isWatched }, deleted)
            } else if let last, last.isWatched {
                (following, played) = (next(after: last, in: ordered), last.lastPlayedAt ?? .distantPast)
            } else { continue }
            guard let following, !following.isWatched, !included.contains(following.id) else { continue }
            entries.append((following, played, 0))
            included.insert(following.id)
        }
        return entries.sorted { ($0.played, $0.position) > ($1.played, $1.position) }.map(\.item)
    }

    /// The first episode not yet watched (an in-progress one resumes); the first when all are watched.
    static func upNext(in episodes: [DownloadItem]) -> DownloadItem? {
        episodes.first { !$0.isWatched } ?? episodes.first
    }
}
