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
        XCTAssertEqual(SiteNames.name(for: "showsite.example"), "Showsite", "the domain, capitalised")
        XCTAssertEqual(SiteNames.name(for: "www.animesite.example"), "Animesite")
        XCTAssertEqual(SiteNames.name(for: "moviesite.example"), "Moviesite")
        XCTAssertEqual(SiteNames.name(for: "seriessite.example"), "Seriessite")
        XCTAssertEqual(SiteNames.name(for: "tools.cdnhost.example"), "Cdnhost")
        XCTAssertEqual(SiteNames.name(for: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(SiteNames.name(for: "localhost"), "localhost")
    }

    func testDisplayTitlesDropTheSiteNameTheLabelShows() {
        XCTAssertEqual(DownloadItem.displayTitle("Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 5 · Showsite", host: "showsite.example"),
                       "Re:Zero kara Hajimeru Isekai Seikatsu 2nd Season Part 2 Ep. 5")
        XCTAssertEqual(DownloadItem.displayTitle("Watch South Park (1997) S29E2 - Watch Series - Seriessite", host: "seriessite.example"),
                       "Watch South Park (1997) S29E2 - Watch Series")
        XCTAssertEqual(DownloadItem.displayTitle("Frieren · Showsite", host: "animesite.example"), "Frieren · Showsite", "only the video's own site")
        XCTAssertEqual(DownloadItem.displayTitle("Showsite", host: "showsite.example"), "Showsite")
    }

    func testSitesFromTypedAddresses() {
        XCTAssertEqual(SiteNames.site(fromInput: "https://www.animesite.example/watch/1?ep=2"), "animesite.example")
        XCTAssertEqual(SiteNames.site(fromInput: " Showsite.example "), "showsite.example")
        XCTAssertEqual(SiteNames.site(fromInput: "othersite.example/home"), "othersite.example")
        XCTAssertNil(SiteNames.site(fromInput: "anime"))
        XCTAssertNil(SiteNames.site(fromInput: ""))
        XCTAssertTrue(SiteMatch.matches(host: "watch.Showsite.example", site: "showsite.example"))
        XCTAssertTrue(SiteMatch.matches(host: "www.showsite.example", site: "showsite.example"))
        XCTAssertFalse(SiteMatch.matches(host: "notshowsite.example", site: "showsite.example"))
        XCTAssertFalse(SiteMatch.matches(host: "showsite.example", site: ""))
    }

    func testDownloadsGetTheirSiteLabelAndMatchingRules() throws {
        let store = makeStore()
        store.create(name: "Anime", sites: ["showsite.example", "animesite.example"])
        let showPage = video("Sample Show Ep. 1 · Showsite", from: "https://showsite.example/anime/vpoY93SPHAQZP9soq/p-1-dub")
        let animePage = video("Frieren Ep. 1", from: "https://www.animesite.example/watch/154587/frieren?ep=1")
        let hydra = video("Movie", from: "https://moviesite.example/movie/1")
        [showPage, animePage, hydra].forEach(store.applyAutomaticLabels)
        XCTAssertEqual(names(showPage, store), ["Anime", "Showsite"])
        XCTAssertEqual(names(animePage, store), ["Anime", "Animesite"])
        XCTAssertEqual(names(hydra, store), ["Moviesite"])
        let second = video("Sample Show Ep. 2 · Showsite", from: "https://showsite.example/anime/vpoY93SPHAQZP9soq/p-2-dub")
        store.applyAutomaticLabels(to: second)
        XCTAssertEqual(store.labels.filter { $0.name == "Showsite" }.count, 1, "one site label per site")
        XCTAssertEqual(showPage.labelIDs?.count, 2)
    }

    func testSiteLabelsCanBeTurnedOff() {
        let store = makeStore()
        store.labelsDownloadsWithSite = false
        store.create(name: "Anime", sites: ["showsite.example"])
        let item = video("Episode", from: "https://showsite.example/anime/x")
        store.applyAutomaticLabels(to: item)
        XCTAssertEqual(names(item, store), ["Anime"])
        XCTAssertFalse(makeStore().labelsDownloadsWithSite, "the setting is remembered")
    }

    func testExistingVideosGetSiteLabelsOnce() {
        let store = makeStore()
        let first = video("Episode 1", from: "https://showsite.example/anime/x/p-1-dub")
        let other = video("South Park S29E2", from: "https://seriessite.example/watch/tv/2190")
        store.backfillSiteLabelsIfNeeded()
        XCTAssertEqual(names(first, store), ["Showsite"])
        XCTAssertEqual(names(other, store), ["Seriessite"])
        first.labelIDs = []
        makeStore().backfillSiteLabelsIfNeeded()
        XCTAssertEqual(first.labelIDs, [], "a label the viewer removed isn't added back")
    }

    func testRulesCanBeAppliedToSavedVideosAndDeletingKeepsVideos() throws {
        let store = makeStore()
        let item = video("Episode", from: "https://showsite.example/anime/x")
        let label = try XCTUnwrap(store.create(name: "Anime"))
        XCTAssertTrue(store.unlabelledMatches(for: label).isEmpty)
        label.sites = ["showsite.example"]
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
