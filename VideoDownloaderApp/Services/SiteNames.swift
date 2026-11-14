import Foundation

enum SiteNames {
    /// Display names for sites whose domain doesn't read well on its own.
    private static let knownNames = ["my***REMOVED***": "My***REMOVED***", "***REMOVED***": "***REMOVED***", "***REMOVED***": "***REMOVED***"]

    static func name(for host: String) -> String {
        let site = normalized(host)
        if let starter = Bookmark.knownSites.first(where: { $0.1.host.map(normalized).map { SiteMatch.matches(host: site, site: $0) } ?? false }) {
            return starter.0
        }
        let parts = site.split(separator: ".").map(String.init)
        // Addresses and single-word hosts such as "localhost" stay as they are.
        guard parts.count >= 2, Int(parts.last ?? "") == nil else { return site }
        let domain = parts[parts.count - 2]
        if let known = knownNames[domain] { return known }
        return domain.prefix(1).uppercased() + domain.dropFirst()
    }

    static func normalized(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    static func site(fromInput input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)?.host
        guard let host, !host.isEmpty, host.contains(".") || host == "localhost" else { return nil }
        return normalized(host)
    }
}

enum SiteMatch {
    static func matches(host: String, site: String) -> Bool {
        let host = SiteNames.normalized(host)
        let site = SiteNames.normalized(site)
        return !site.isEmpty && (host == site || host.hasSuffix("." + site))
    }
}

extension DownloadItem {
    /// Drops a trailing site name the site label already shows, so long titles keep the episode number.
    var displayTitle: String { Self.displayTitle(title, host: sourcePageURL.host) }

    static func displayTitle(_ title: String, host: String?) -> String {
        guard let host else { return title }
        let name = SiteNames.name(for: host).lowercased()
        for separator in [" · ", " - ", " – ", " — ", " | "] {
            let suffix = separator + name
            if title.count > suffix.count, title.lowercased().hasSuffix(suffix) { return String(title.dropLast(suffix.count)) }
        }
        return title
    }
}
