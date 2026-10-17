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
        let testedElsewhere = Bookmark.testedSites.filter { tested in
            !Bookmark.starters.contains { SiteMatch.matches(host: $0.1.host!, site: tested.1.host!) }
        }
        XCTAssertEqual(bookmarks.count, Bookmark.starters.count + testedElsewhere.count + 1)
        XCTAssertTrue(bookmarks.contains { $0.url == personal && $0.title == "My show" })
        XCTAssertFalse(bookmarks.contains { Bookmark.oldStarterURLs.contains($0.url.absoluteString) })
        for (_, url) in Bookmark.starters { XCTAssertTrue(bookmarks.contains { $0.url == url }) }
        StarterBookmarks.install(in: context, preferences: preferences)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), bookmarks.count)
    }

    /// A library that already had the earlier tested sites gets only the newer ones, once; one
    /// bookmark deleted since isn't added back.
    func testSitesFromALaterSurveyAreAddedWithoutRestoringDeletedOnes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(Bookmark(title: "Mine", url: URL(string: "https://www.google.com/")!))
        try context.save()
        let suiteName = "BrowserCollectionsStoreTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        for key in ["starterBookmarksV2", "seededBookmarks", "testedSiteBookmarksV3", "testedSiteBookmarksV4"] { preferences.set(true, forKey: key) }

        StarterBookmarks.install(in: context, preferences: preferences)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bookmark>()).map(\.title).sorted(), ["***REMOVED***", "***REMOVED***", "Mine", "***REMOVED***", "***REMOVED***s"])

        try context.fetch(FetchDescriptor<Bookmark>()).filter { $0.title == "***REMOVED***" }.forEach(context.delete)
        try context.save()
        StarterBookmarks.install(in: context, preferences: preferences)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bookmark>()).map(\.title).sorted(), ["***REMOVED***", "Mine", "***REMOVED***", "***REMOVED***s"])
    }

    /// A library with its own bookmarks gets each tested site once, unless a bookmark already
    /// opens that site; nothing is removed, and it happens only once.
    func testTestedSitesAreAddedOnceBesideExistingBookmarks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let own = ["https://www.google.com/", "https://www.***REMOVED***.tv/", "https://my***REMOVED***.lol/home/", "https://***REMOVED***.to/anime?tr=dub"]
        for url in own { context.insert(Bookmark(title: "Mine", url: URL(string: url)!)) }
        try context.save()

        let suiteName = "BrowserCollectionsStoreTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        // Set up by an earlier version, whose starters weren't added to a library with bookmarks.
        preferences.set(true, forKey: "starterBookmarksV2")
        preferences.set(true, forKey: "seededBookmarks")
        StarterBookmarks.install(in: context, preferences: preferences)

        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        let added = bookmarks.filter { $0.title != "Mine" }.map(\.title).sorted()
        // ***REMOVED*** moved to ***REMOVED***.to, a different site from the bookmarked ***REMOVED***.tv.
        XCTAssertEqual(added, ["***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***", "***REMOVED***s"])
        XCTAssertEqual(bookmarks.filter { $0.title == "Mine" }.count, own.count)

        bookmarks.first { $0.title == "***REMOVED***" }.map(context.delete)
        try context.save()
        StarterBookmarks.install(in: context, preferences: preferences)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), bookmarks.count - 1, "a deleted site stays deleted")
        XCTAssertEqual(SiteNames.name(for: "www.***REMOVED***.com"), "***REMOVED***")
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

    func testHistoryIsCappedByDroppingTheOldestVisits() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let store = BrowserHistoryStore(context: context)
        let total = BrowserHistoryStore.maximumEntries + 3
        for index in 0..<total {
            store.record(URL(string: "https://example.com/page/\(index)")!, title: "Page \(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BrowsingHistoryEntry>()), BrowserHistoryStore.maximumEntries)
        let urls = Set(try context.fetch(FetchDescriptor<BrowsingHistoryEntry>()).map(\.url.absoluteString))
        for dropped in 0..<3 { XCTAssertFalse(urls.contains("https://example.com/page/\(dropped)")) }
        XCTAssertTrue(urls.contains("https://example.com/page/\(total - 1)"))
        // Revisiting a page updates its row instead of adding (and evicting) another.
        store.record(URL(string: "https://example.com/page/\(total - 1)")!, title: "Again", at: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BrowsingHistoryEntry>()), BrowserHistoryStore.maximumEntries)
        XCTAssertTrue(try context.fetch(FetchDescriptor<BrowsingHistoryEntry>()).map(\.url.absoluteString).contains("https://example.com/page/3"))
    }

    /// Every shipped site is filed; the user's own bookmarks of a shipped site join its folder.
    func testBookmarksAreGroupedIntoFolders() {
        for (title, url) in Bookmark.knownSites {
            XCTAssertNotEqual(Bookmark(title: title, url: url).folder, .mine, "\(title) has no folder")
        }
        XCTAssertEqual(Bookmark(title: "Ep 2", url: URL(string: "https://www.***REMOVED***.to/watch/1/x?ep=2")!).folder, .autoDownload)
        XCTAssertEqual(Bookmark(title: "***REMOVED***", url: URL(string: "https://***REMOVED***tv.to/watch/x/ep-3")!).folder, .needsTap)
        XCTAssertEqual(Bookmark(title: "Mine", url: URL(string: "https://example.com/")!).folder, .mine)
    }
}
