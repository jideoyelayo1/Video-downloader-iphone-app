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

        guard !preferences.bool(forKey: "starterBookmarksV2") else { return }
        let old = existing.filter { Bookmark.oldStarterURLs.contains($0.url.absoluteString) }
        old.forEach(context.delete)
        if !old.isEmpty || (existing.isEmpty && !preferences.bool(forKey: "seededBookmarks")) {
            addMissing(in: context, existing: existing.filter { bookmark in !old.contains(where: { $0 === bookmark }) })
        }
        try? context.save()
        preferences.set(true, forKey: "starterBookmarksV2")
        preferences.set(true, forKey: "seededBookmarks")
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

    func record(_ rawURL: URL, title: String, at date: Date = Date()) {
        guard let url = Self.pageURL(rawURL) else { return }
        guard let entries = try? context.fetch(FetchDescriptor<BrowsingHistoryEntry>()) else { return }
        let name = cleanTitle(title, for: url)
        if let entry = entries.first(where: { $0.url == url }) {
            entry.title = name
            entry.visitedAt = date
        } else {
            context.insert(BrowsingHistoryEntry(title: name, url: url, visitedAt: date))
            if entries.count >= Self.maximumEntries {
                for old in entries.sorted(by: { $0.visitedAt < $1.visitedAt }).prefix(entries.count - Self.maximumEntries + 1) {
                    context.delete(old)
                }
            }
        }
        try? context.save()
    }

    func updateTitle(for rawURL: URL, title: String) {
        guard let url = Self.pageURL(rawURL), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entries = try? context.fetch(FetchDescriptor<BrowsingHistoryEntry>()),
              let entry = entries.first(where: { $0.url == url }) else { return }
        entry.title = cleanTitle(title, for: url)
        try? context.save()
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
