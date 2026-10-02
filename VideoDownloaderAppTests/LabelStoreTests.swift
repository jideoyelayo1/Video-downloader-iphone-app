import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class LabelStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        container = try LibrarySchema.container(inMemory: true)
        suite = "LabelStoreTests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
    }

    private func makeStore() -> LabelStore { LabelStore(context: container.mainContext, preferences: preferences) }

    private func video(_ title: String, from page: String) -> DownloadItem {
        let item = DownloadItem(title: title, remoteURL: URL(string: "https://cdn.example/\(UUID().uuidString).mp4")!,
                                sourcePageURL: URL(string: page)!, kind: .video, status: .completed)
        container.mainContext.insert(item)
        return item
    }

    private func names(_ item: DownloadItem, _ store: LabelStore) -> Set<String> {
        Set((item.labelIDs ?? []).compactMap { id in store.labels.first { $0.id == id }?.name })
    }

    func testSiteNamesReadWell() {
        XCTAssertEqual(SiteNames.name(for: "***REMOVED***.to"), "***REMOVED***", "starter bookmarks give the name")
        XCTAssertEqual(SiteNames.name(for: "www.***REMOVED***.to"), "***REMOVED***")
        XCTAssertEqual(SiteNames.name(for: "***REMOVED***.ws"), "***REMOVED***")
        XCTAssertEqual(SiteNames.name(for: "my***REMOVED***.lol"), "My***REMOVED***")
        XCTAssertEqual(SiteNames.name(for: "tools.***REMOVED***.rsvp"), "***REMOVED***")
        XCTAssertEqual(SiteNames.name(for: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(SiteNames.name(for: "localhost"), "localhost")
    }

    func testDisplayTitlesDropTheSiteNameTheLabelShows() {
        XCTAssertEqual(DownloadItem.displayTitle("Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 5 · ***REMOVED***", host: "***REMOVED***.to"),
                       "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 5")
        XCTAssertEqual(DownloadItem.displayTitle("Watch South Park (1997) S29E2 - Watch Series - My***REMOVED***", host: "my***REMOVED***.lol"),
                       "Watch South Park (1997) S29E2 - Watch Series")
        XCTAssertEqual(DownloadItem.displayTitle("Frieren · ***REMOVED***", host: "***REMOVED***.to"), "Frieren · ***REMOVED***", "only the video's own site")
        XCTAssertEqual(DownloadItem.displayTitle("***REMOVED***", host: "***REMOVED***.to"), "***REMOVED***")
    }

    func testSitesFromTypedAddresses() {
        XCTAssertEqual(SiteNames.site(fromInput: "https://www.***REMOVED***.to/watch/1?ep=2"), "***REMOVED***.to")
        XCTAssertEqual(SiteNames.site(fromInput: " ***REMOVED***.to "), "***REMOVED***.to")
        XCTAssertEqual(SiteNames.site(fromInput: "***REMOVED***.to/home"), "***REMOVED***.to")
        XCTAssertNil(SiteNames.site(fromInput: "anime"))
        XCTAssertNil(SiteNames.site(fromInput: ""))
        XCTAssertTrue(SiteMatch.matches(host: "watch.***REMOVED***.to", site: "***REMOVED***.to"))
        XCTAssertTrue(SiteMatch.matches(host: "www.***REMOVED***.to", site: "***REMOVED***.to"))
        XCTAssertFalse(SiteMatch.matches(host: "not***REMOVED***.to", site: "***REMOVED***.to"))
        XCTAssertFalse(SiteMatch.matches(host: "***REMOVED***.to", site: ""))
    }

    func testDownloadsGetTheirSiteLabelAndMatchingRules() throws {
        let store = makeStore()
        store.create(name: "Anime", sites: ["***REMOVED***.to", "***REMOVED***.to"])
        let ***REMOVED*** = video("***REMOVED*** Ep. 1 · ***REMOVED***", from: "https://***REMOVED***.to/anime/vpoY93SPHAQZP9soq/p-1-dub")
        let ***REMOVED*** = video("Frieren Ep. 1", from: "https://www.***REMOVED***.to/watch/154587/frieren?ep=1")
        let hydra = video("Movie", from: "https://***REMOVED***.ws/movie/1")
        [***REMOVED***, ***REMOVED***, hydra].forEach(store.applyAutomaticLabels)
        XCTAssertEqual(names(***REMOVED***, store), ["Anime", "***REMOVED***"])
        XCTAssertEqual(names(***REMOVED***, store), ["Anime", "***REMOVED***"])
        XCTAssertEqual(names(hydra, store), ["***REMOVED***"])
        let second = video("***REMOVED*** Ep. 2 · ***REMOVED***", from: "https://***REMOVED***.to/anime/vpoY93SPHAQZP9soq/p-2-dub")
        store.applyAutomaticLabels(to: second)
        XCTAssertEqual(store.labels.filter { $0.name == "***REMOVED***" }.count, 1, "one site label per site")
        XCTAssertEqual(***REMOVED***.labelIDs?.count, 2)
    }

    func testSiteLabelsCanBeTurnedOff() {
        let store = makeStore()
        store.labelsDownloadsWithSite = false
        store.create(name: "Anime", sites: ["***REMOVED***.to"])
        let item = video("Episode", from: "https://***REMOVED***.to/anime/x")
        store.applyAutomaticLabels(to: item)
        XCTAssertEqual(names(item, store), ["Anime"])
        XCTAssertFalse(makeStore().labelsDownloadsWithSite, "the setting is remembered")
    }

    func testExistingVideosGetSiteLabelsOnce() {
        let store = makeStore()
        let first = video("Episode 1", from: "https://***REMOVED***.to/anime/x/p-1-dub")
        let other = video("South Park S29E2", from: "https://my***REMOVED***.lol/watch/tv/2190")
        store.backfillSiteLabelsIfNeeded()
        XCTAssertEqual(names(first, store), ["***REMOVED***"])
        XCTAssertEqual(names(other, store), ["My***REMOVED***"])
        first.labelIDs = []
        makeStore().backfillSiteLabelsIfNeeded()
        XCTAssertEqual(first.labelIDs, [], "a label the viewer removed isn't added back")
    }

    func testRulesCanBeAppliedToSavedVideosAndDeletingKeepsVideos() throws {
        let store = makeStore()
        let item = video("Episode", from: "https://***REMOVED***.to/anime/x")
        let label = try XCTUnwrap(store.create(name: "Anime"))
        XCTAssertTrue(store.unlabelledMatches(for: label).isEmpty)
        label.sites = ["***REMOVED***.to"]
        XCTAssertEqual(store.unlabelledMatches(for: label).count, 1)
        store.applyToExisting(label)
        XCTAssertEqual(item.labelIDs, [label.id])
        XCTAssertTrue(store.unlabelledMatches(for: label).isEmpty)
        XCTAssertTrue(store.create(name: "anime") === label, "names are unique, ignoring case")

        store.toggle(label, on: item)
        XCTAssertEqual(item.labelIDs, [])
        store.toggle(label, on: item)
        store.delete(label)
        XCTAssertEqual(item.labelIDs, [])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<DownloadItem>()).count, 1)
    }
}
