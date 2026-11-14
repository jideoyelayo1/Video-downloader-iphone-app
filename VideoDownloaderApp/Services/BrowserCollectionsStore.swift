import Foundation
import SwiftData

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
