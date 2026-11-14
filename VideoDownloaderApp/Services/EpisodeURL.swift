import Foundation

/// Next-episode page from a numbered address (`?ep=9`, `/episode-2/`, `/tv/<id>/<s>/2`, `S1E2`), else nil.
enum EpisodeURL {
    private static let queryNames = ["ep", "episode", "e"]
    private static let seasonEpisode = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(s\d{1,2})(e)(\d{1,4})(?![0-9])"#)
    private static let episodeInPath = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9])(episode|ep|p|e)([-_/]?)(\d{1,4})(?![0-9])"#)
    private static let tvSeasonEpisode = try! NSRegularExpression(pattern: #"(?i)(/tv/\d+/)(\d{1,3}/)(\d{1,4})/?$"#)

    private static func episodeMatch(in path: String) -> NSTextCheckingResult? {
        let range = NSRange(path.startIndex..., in: path)
        return seasonEpisode.matches(in: path, range: range).last ?? episodeInPath.matches(in: path, range: range).last
            ?? tvSeasonEpisode.firstMatch(in: path, range: range)
    }

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
        let match = episodeMatch(in: path)
        guard let match, let numberRange = Range(match.range(at: 3), in: path), let number = Int(path[numberRange]) else { return nil }
        let digits = path[numberRange].count
        let next = String(format: "%0\(digits)d", number + step)
        components.percentEncodedPath = path.replacingCharacters(in: numberRange, with: next)
        return components.url
    }

    static func number(in url: URL) -> Int? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let item = components.queryItems?.first(where: { queryNames.contains($0.name.lowercased()) }), let value = Int(item.value ?? "") { return value }
        let path = components.percentEncodedPath
        let match = episodeMatch(in: path)
        return match.flatMap { Range($0.range(at: 3), in: path) }.flatMap { Int(path[$0]) }
    }
}

extension EpisodeURL {
    /// Some sites title every episode alike, so the address's episode number goes in before the site name.
    static func title(_ title: String, numberedFrom page: URL) -> String {
        guard !title.isEmpty, ShowSuggestion.parse(DownloadItem.displayTitle(title, host: page.host)).episode == nil,
              let number = number(in: page) else { return title }
        let base = DownloadItem.displayTitle(title, host: page.host)
        return base + " Ep. \(number)" + title.dropFirst(base.count)
    }
}
