import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class BrowserCollectionsStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Bookmark.self, BrowsingHistoryEntry.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testStarterMigrationReplacesOldEpisodeLinksAndKeepsPersonalBookmark() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for url in Bookmark.oldStarterURLs {
            context.insert(Bookmark(title: "Old starter", url: URL(string: url)!))
        }
        let personal = URL(string: "https://example.com/my-show/episode-2")!
        context.insert(Bookmark(title: "My show", url: personal))
        try context.save()

        let suiteName = "BrowserCollectionsStoreTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        StarterBookmarks.install(in: context, preferences: preferences)

        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.count, Bookmark.starters.count + 1)
        XCTAssertTrue(bookmarks.contains { $0.url == personal && $0.title == "My show" })
        XCTAssertFalse(bookmarks.contains { Bookmark.oldStarterURLs.contains($0.url.absoluteString) })
        for (_, url) in Bookmark.starters { XCTAssertTrue(bookmarks.contains { $0.url == url }) }
        StarterBookmarks.install(in: context, preferences: preferences)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), bookmarks.count)
    }

    func testHistoryKeepsLatestVisitPerPageAndCanBeCleared() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = BrowserHistoryStore(context: context)
        let page = URL(string: "https://example.com/watch?ep=1")!
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        store.record(page, title: "Episode 1", at: first)
        store.record(page, title: "Episode One", at: second)
        store.record(URL(string: "file:///tmp/other.html")!, title: "Local file")

        let entries = try context.fetch(FetchDescriptor<BrowsingHistoryEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Episode One")
        XCTAssertEqual(entries[0].visitedAt, second)
        store.updateTitle(for: page, title: "Final title")
        XCTAssertEqual(entries[0].title, "Final title")
        store.clear()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BrowsingHistoryEntry>()), 0)
    }

    func testAddingHistoryModelKeepsExistingBookmarks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("library.store")
        let savedURL = URL(string: "https://example.com/favourite")!
        do {
            let old = try ModelContainer(for: Bookmark.self, configurations: ModelConfiguration(url: storeURL))
            old.mainContext.insert(Bookmark(title: "Favourite", url: savedURL))
            try old.mainContext.save()
        }

        let upgraded = try ModelContainer(for: Bookmark.self, BrowsingHistoryEntry.self,
                                          configurations: ModelConfiguration(url: storeURL))
        let saved = try upgraded.mainContext.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].url, savedURL)
        BrowserHistoryStore(context: upgraded.mainContext).record(savedURL, title: "Favourite")
        XCTAssertEqual(try upgraded.mainContext.fetchCount(FetchDescriptor<BrowsingHistoryEntry>()), 1)
    }
}
