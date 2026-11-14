import Foundation
import SwiftData

@MainActor
enum StarterBookmarks {
    /// Upgrade only the two episode links shipped by older builds. Personal sites stay untouched.
    static func install(in context: ModelContext, preferences: UserDefaults = .standard, inMemory: Bool = false) {
        guard let existing = try? context.fetch(FetchDescriptor<Bookmark>()) else { return }
        if inMemory {
            if existing.isEmpty { addMissing(in: context, existing: []) }
            return
        }

        if !preferences.bool(forKey: "starterBookmarksV2") {
            let old = existing.filter { Bookmark.oldStarterURLs.contains($0.url.absoluteString) }
            old.forEach(context.delete)
            if !old.isEmpty || (existing.isEmpty && !preferences.bool(forKey: "seededBookmarks")) {
                addMissing(in: context, existing: existing.filter { bookmark in !old.contains(where: { $0 === bookmark }) })
            }
            try? context.save()
            preferences.set(true, forKey: "starterBookmarksV2")
            preferences.set(true, forKey: "seededBookmarks")
        }

        // Each list is added once behind its own flag, so sites the user deleted since aren't added back.
        if !preferences.bool(forKey: "testedSiteBookmarksV3") {
            addMissingSites(Bookmark.testedSites, in: context)
            preferences.set(true, forKey: "testedSiteBookmarksV3")
            preferences.set(true, forKey: "testedSiteBookmarksV4")
            preferences.set(true, forKey: "testedSiteBookmarksV5")
        } else {
            if !preferences.bool(forKey: "testedSiteBookmarksV4") {
                addMissingSites(Bookmark.addedTestedSites, in: context)
                preferences.set(true, forKey: "testedSiteBookmarksV4")
            }
            if !preferences.bool(forKey: "testedSiteBookmarksV5") {
                addMissingSites(Bookmark.laterTestedSites, in: context)
                preferences.set(true, forKey: "testedSiteBookmarksV5")
            }
        }
    }

    private static func addMissingSites(_ sites: [(String, URL)], in context: ModelContext) {
        let hosts = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? []).compactMap(\.url.host)
        for (title, url) in sites {
            guard let site = url.host, !hosts.contains(where: { SiteMatch.matches(host: $0, site: site) }) else { continue }
            context.insert(Bookmark(title: title, url: url))
        }
        try? context.save()
    }

    private static func addMissing(in context: ModelContext, existing: [Bookmark]) {
        let urls = Set(existing.map { $0.url.absoluteString })
        for (title, url) in Bookmark.starters where !urls.contains(url.absoluteString) {
            context.insert(Bookmark(title: title, url: url))
        }
        try? context.save()
    }
}

@MainActor
final class BrowserHistoryStore {
    static let maximumEntries = 500
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    /// Runs on every page load, so it looks up one row rather than loading the whole history.
    func record(_ rawURL: URL, title: String, at date: Date = Date()) {
        guard let url = Self.pageURL(rawURL) else { return }
        let name = cleanTitle(title, for: url)
        if let entry = entry(for: url) {
            entry.title = name
            entry.visitedAt = date
        } else {
            let count = (try? context.fetchCount(FetchDescriptor<BrowsingHistoryEntry>())) ?? 0
            if count >= Self.maximumEntries {
                var oldest = FetchDescriptor<BrowsingHistoryEntry>(sortBy: [SortDescriptor(\.visitedAt)])
                oldest.fetchLimit = count - Self.maximumEntries + 1
                (try? context.fetch(oldest))?.forEach(context.delete)
            }
            context.insert(BrowsingHistoryEntry(title: name, url: url, visitedAt: date))
        }
        try? context.save()
    }

    func updateTitle(for rawURL: URL, title: String) {
        guard let url = Self.pageURL(rawURL), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entry = entry(for: url) else { return }
        let name = cleanTitle(title, for: url)
        guard entry.title != name else { return }
        entry.title = name
        try? context.save()
    }

    private func entry(for url: URL) -> BrowsingHistoryEntry? {
        var descriptor = FetchDescriptor<BrowsingHistoryEntry>(predicate: #Predicate { $0.url == url })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func clear() {
        guard let entries = try? context.fetch(FetchDescriptor<BrowsingHistoryEntry>()) else { return }
        entries.forEach(context.delete)
        try? context.save()
    }

    private func cleanTitle(_ title: String, for url: URL) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (url.host ?? url.absoluteString) : trimmed
    }

    private static func pageURL(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { return nil }
        parts.user = nil
        parts.password = nil
        return parts.url
    }
}
