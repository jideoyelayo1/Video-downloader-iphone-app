import Foundation

/// Works out the page of the next episode from an episode's address, for sites that number
/// their episode pages: ***REMOVED*** `/p-9-dub`, ***REMOVED*** `?ep=9`, My***REMOVED*** `/episode-2/`,
/// ***REMOVED*** `/episode/2`, `S1E2`. Sites whose addresses don't contain the episode number
/// (***REMOVED***'s `/play/<id>/<hash>`) return nil.
enum EpisodeURL {
    private static let queryNames = ["ep", "episode", "e"]
    private static let seasonEpisode = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(s\d{1,2})(e)(\d{1,4})(?![0-9])"#)
    private static let episodeInPath = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(episode|ep|p|e)([-_/]?)(\d{1,4})(?![0-9])"#)

    static func next(after url: URL, by step: Int = 1) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if var items = components.queryItems,
           let index = items.firstIndex(where: { queryNames.contains($0.name.lowercased()) && Int($0.value ?? "") != nil }),
           let number = Int(items[index].value ?? "") {
            items[index].value = String(number + step)
            components.queryItems = items
            return components.url
        }
        let path = components.percentEncodedPath
        let range = NSRange(path.startIndex..., in: path)
        let match = seasonEpisode.matches(in: path, range: range).last ?? episodeInPath.matches(in: path, range: range).last
        guard let match, let numberRange = Range(match.range(at: 3), in: path), let number = Int(path[numberRange]) else { return nil }
        let digits = path[numberRange].count
        let next = String(format: "%0\(digits)d", number + step)
        components.percentEncodedPath = path.replacingCharacters(in: numberRange, with: next)
        return components.url
    }

    /// The episode number in an address, when there is one.
    static func number(in url: URL) -> Int? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let item = components.queryItems?.first(where: { queryNames.contains($0.name.lowercased()) }), let value = Int(item.value ?? "") { return value }
        let path = components.percentEncodedPath
        let range = NSRange(path.startIndex..., in: path)
        let match = seasonEpisode.matches(in: path, range: range).last ?? episodeInPath.matches(in: path, range: range).last
        return match.flatMap { Range($0.range(at: 3), in: path) }.flatMap { Int(path[$0]) }
    }
}

extension EpisodeURL {
    /// Adds the address's episode number to a title that lacks one, before a trailing site
    /// name: ***REMOVED*** titles every episode "Watch Attack on Titan · ***REMOVED***", so episode 2 becomes
    /// "Watch Attack on Titan Ep. 2 · ***REMOVED***".
    static func title(_ title: String, numberedFrom page: URL) -> String {
        guard !title.isEmpty, ShowSuggestion.parse(DownloadItem.displayTitle(title, host: page.host)).episode == nil,
              let number = number(in: page) else { return title }
        let base = DownloadItem.displayTitle(title, host: page.host)
        return base + " Ep. \(number)" + title.dropFirst(base.count)
    }
}
