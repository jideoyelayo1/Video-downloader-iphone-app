import AVFoundation
import AVKit
import SwiftData
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    private var fileName: String!
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try LibrarySchema.container(inMemory: true)
        fileName = "playback-test-\(UUID().uuidString).mp4"
        let source = try XCTUnwrap(FixtureSet.resourceURL(named: "fixture_captions.mp4", in: Bundle(for: LocalMediaServer.self)))
        try FileManager.default.copyItem(at: source, to: DownloadStorage.libraryDirectory.appendingPathComponent(fileName))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: DownloadStorage.libraryDirectory.appendingPathComponent(fileName))
    }

    private func makeItem(in context: ModelContext) -> DownloadItem {
        let item = DownloadItem(title: "Captioned", remoteURL: URL(string: "https://cdn.example/captions.mp4")!,
                                sourcePageURL: URL(string: "https://site.example/watch")!, kind: .video, status: .completed)
        item.localFileName = fileName
        context.insert(item)
        return item
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("\(description) — not met within \(timeout) s") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Opening and closing a saved video repeatedly must not keep old players alive.
    func testClosedPlayersAreReleased() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = "PlaybackCoordinatorTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log, preferences: preferences, presentsPlayer: false)
        let item = makeItem(in: container.mainContext)

        var released: [() -> Bool] = []
        for _ in 0..<3 {
            coordinator.open(item, at: 0)
            try await waitUntil("player ready") { coordinator.controller.player != nil && !coordinator.isLoading }
            weak var player = coordinator.controller.player
            weak var playerItem = coordinator.controller.player?.currentItem
            released.append { player == nil && playerItem == nil }
            try await Task.sleep(for: .milliseconds(300))
            coordinator.close()
        }
        try await waitUntil("closed players and items released") { released.allSatisfy { $0() } }
        XCTAssertNil(coordinator.controller.player)
    }

    /// Re-hosting one player controller in every new presentation kept each earlier presentation's
    /// views alive (about 0.75 MB per video opened). Each video now gets its own controller.
    func testEachVideoGetsItsOwnControllerAndThePreviousOneIsReleased() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log,
                                              preferences: try XCTUnwrap(UserDefaults(suiteName: "PlaybackCoordinatorTests-controllers")), presentsPlayer: false)
        let item = makeItem(in: container.mainContext)

        weak var first: AVPlayerViewController?
        do {
            coordinator.open(item, at: 0)
            try await waitUntil("first video ready") { coordinator.controller.player != nil && !coordinator.isLoading }
            first = coordinator.controller
            XCTAssertTrue(first?.delegate === coordinator)
            coordinator.close()
        }
        coordinator.open(item, at: 0)
        try await waitUntil("second video ready") { coordinator.controller.player != nil && !coordinator.isLoading }
        XCTAssertFalse(coordinator.controller === first)
        XCTAssertTrue(coordinator.controller.delegate === coordinator)
        XCTAssertTrue(coordinator.controller.allowsPictureInPicturePlayback)
        try await waitUntil("previous controller released") { first == nil }
        coordinator.close()
    }

    /// ***REMOVED***-style subtitles saved beside the video are listed and drawn over it.
    func testSiteSubtitlesAreListedSelectedByDefaultAndDrawn() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log,
                                              preferences: try XCTUnwrap(UserDefaults(suiteName: "PlaybackCoordinatorTests-site-\(UUID().uuidString)")), presentsPlayer: false)
        let item = makeItem(in: container.mainContext)
        let page = server.url("/page/tracks.html")
        await SubtitleStore.save([SubtitleTrack(url: server.url("/subs/es.vtt"), label: "Español", language: "es", isDefault: false, referer: page),
                                  SubtitleTrack(url: server.url("/subs/en.vtt"), label: "English", language: "en", isDefault: true, referer: page)],
                                 for: item.id) { _ in nil }
        defer { SubtitleStore.remove(for: item.id) }

        coordinator.open(item, at: 0)
        try await waitUntil("player ready") { coordinator.controller.player != nil && !coordinator.isLoading }
        // The captioned fixture has embedded English tracks; the site files follow them, and the
        // site's English is told apart from the embedded one.
        XCTAssertEqual(Array(coordinator.captionNames.suffix(2)), ["Español", "English (site)"])
        let english = coordinator.captionNames.count - 1
        coordinator.chooseCaption(english)
        try await waitUntil("English cue drawn") { coordinator.siteSubtitleText == "Fixture English line" }
        coordinator.chooseCaption(english - 1)
        try await waitUntil("Spanish cue drawn") { coordinator.siteSubtitleText == "Línea de prueba & más" }
        coordinator.chooseCaption(nil)
        XCTAssertNil(coordinator.siteSubtitleText)
        coordinator.close()
    }

    func testViewerLanguageThenSiteDefaultThenFirst() {
        let saved = { (language: String, isDefault: Bool) in SubtitleStore.Saved(fileName: "x", label: language, language: language, isDefault: isDefault) }
        // ***REMOVED*** marks its first track (Arabic) as default; an English-speaking viewer gets English.
        XCTAssertEqual(PlaybackCoordinator.defaultSiteIndex([saved("ar", true), saved("en", false)], preferredLanguages: ["en-GB"]), 1)
        XCTAssertEqual(PlaybackCoordinator.defaultSiteIndex([saved("ar", false), saved("en", true)], preferredLanguages: ["ja"]), 1)
        XCTAssertEqual(PlaybackCoordinator.defaultSiteIndex([saved("ar", false), saved("fr", false)], preferredLanguages: ["ja"]), 0)
        XCTAssertEqual(PlaybackCoordinator.menuNames(embedded: ["English"], site: ["English", "Español"]), ["English", "English (site)", "Español"])
    }

    func testMissingFileShowsAnErrorWithoutOpeningThePlayer() {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log, presentsPlayer: false)
        let item = makeItem(in: container.mainContext)
        item.localFileName = "missing-\(UUID().uuidString).mp4"
        coordinator.open(item, at: 0)
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(coordinator.controller.player)
        XCTAssertEqual(coordinator.errorMessage?.contains("missing"), true)
        coordinator.clearError()
        XCTAssertNil(coordinator.errorMessage)
    }

    /// Built-in captions are chosen in AVKit's own menu; the app remembers that choice.
    func testChoiceInThePlayersOwnMenuIsRemembered() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = "PlaybackCoordinatorTests-menu-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log, preferences: preferences, presentsPlayer: false)
        let item = makeItem(in: container.mainContext)
        coordinator.open(item, at: 0)
        try await waitUntil("player ready") { coordinator.controller.player != nil && !coordinator.isLoading }
        // Captions start on with full subtitles, not the forced-only track the system prefers.
        XCTAssertEqual(coordinator.captionNames, ["English"])
        XCTAssertEqual(coordinator.selectedCaption, 0)
        // Changes just after opening are AVKit's automatic ones, which the app reverts; a viewer's
        // tap in the menu comes later.
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(preferences.string(forKey: CaptionPreference.defaultsKey), "the app's own default isn't a viewer choice")

        let playerItem = try XCTUnwrap(coordinator.controller.player?.currentItem)
        let loadedGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        // AVKit's Subtitles > Off selects the forced-only track on iOS 26.
        let forced = try XCTUnwrap(group.options.first(where: PlaybackCoordinator.isForcedOnly))
        playerItem.select(forced, in: group)
        try await waitUntil("Off remembered") { preferences.string(forKey: CaptionPreference.defaultsKey) == CaptionPreference.forcedOnly }
        XCTAssertNil(coordinator.selectedCaption)
        coordinator.close()

        // The next playback starts with captions off: the forced-only track, as AVKit shows Off.
        coordinator.open(item, at: 0)
        try await waitUntil("player ready again") { coordinator.controller.player != nil && !coordinator.isLoading }
        XCTAssertNil(coordinator.selectedCaption)
        let reopened = try XCTUnwrap(coordinator.controller.player?.currentItem)
        XCTAssertTrue(reopened.currentMediaSelection.selectedMediaOption(in: group).map(PlaybackCoordinator.isForcedOnly) ?? true)
        coordinator.close()
    }

    /// AVKit changes the selection right after it takes over a new player; the app keeps its own.
    func testAutomaticSelectionJustAfterOpeningIsReverted() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = "PlaybackCoordinatorTests-auto-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(CaptionPreference.off, forKey: CaptionPreference.defaultsKey)
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log, preferences: preferences, presentsPlayer: false)
        let item = makeItem(in: container.mainContext)
        coordinator.open(item, at: 0)
        try await waitUntil("player ready") { coordinator.controller.player != nil && !coordinator.isLoading }
        XCTAssertNil(coordinator.selectedCaption)
        let playerItem = try XCTUnwrap(coordinator.controller.player?.currentItem)
        let loadedGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        let english = try XCTUnwrap(group.options.first { !PlaybackCoordinator.isForcedOnly($0) })
        playerItem.select(english, in: group)  // what AVKit does on its own at this point
        try await waitUntil("Off restored") {
            playerItem.currentMediaSelection.selectedMediaOption(in: group).map(PlaybackCoordinator.isForcedOnly) ?? true
        }
        XCTAssertNil(coordinator.selectedCaption)
        XCTAssertEqual(preferences.string(forKey: CaptionPreference.defaultsKey), CaptionPreference.off)
        coordinator.close()
    }

    /// On iOS 18 AVKit's Off selects no track at all; that is remembered as such.
    func testOffWithoutForcedTrackIsRememberedSeparately() async throws {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = "PlaybackCoordinatorTests-none-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = PlaybackCoordinator(context: container.mainContext, diagnostics: log, preferences: preferences, presentsPlayer: false)
        let item = makeItem(in: container.mainContext)
        coordinator.open(item, at: 0)
        try await waitUntil("player ready") { coordinator.controller.player != nil && !coordinator.isLoading }
        try await Task.sleep(for: .seconds(2))
        let playerItem = try XCTUnwrap(coordinator.controller.player?.currentItem)
        let loadedGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        playerItem.select(nil, in: group)
        try await waitUntil("Off remembered") { preferences.string(forKey: CaptionPreference.defaultsKey) == CaptionPreference.off }
        coordinator.close()

        coordinator.open(item, at: 0)
        try await waitUntil("player ready again") { coordinator.controller.player != nil && !coordinator.isLoading }
        let reopened = try XCTUnwrap(coordinator.controller.player?.currentItem)
        XCTAssertNil(reopened.currentMediaSelection.selectedMediaOption(in: group), "no track at all, as the viewer left it")
        coordinator.close()
    }

    private func makeCoordinator() -> PlaybackCoordinator {
        let log = DiagnosticsLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let preferences = UserDefaults(suiteName: "PlaybackCoordinatorTests-\(UUID().uuidString)")!
        return PlaybackCoordinator(context: container.mainContext, diagnostics: log, preferences: preferences, presentsPlayer: false)
    }

    func testPlayingToTheEndMarksTheVideoWatched() async throws {
        let coordinator = makeCoordinator()
        let item = makeItem(in: container.mainContext)
        coordinator.open(item, at: 0)
        XCTAssertNotNil(item.lastPlayedAt)
        try await waitUntil("player ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        XCTAssertEqual(try XCTUnwrap(item.duration), 5, accuracy: 0.5, "the length is recorded for progress and the 90% rule")
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: coordinator.controller.player?.currentItem)
        try await waitUntil("watched") { item.isWatched }
        XCTAssertEqual(item.playbackPosition, 0)
        coordinator.close()
        XCTAssertTrue(item.isWatched)
    }

    /// Closing during the credits (the last 10%) counts as watched; closing halfway keeps the resume point.
    func testClosingInTheLastTenPercentMarksTheVideoWatched() async throws {
        let coordinator = makeCoordinator()
        let item = makeItem(in: container.mainContext)
        for (position, watched) in [(2.5, false), (4.7, true)] {
            item.setWatched(false)
            coordinator.open(item, at: 0)
            try await waitUntil("player ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
            let player = try XCTUnwrap(coordinator.controller.player)
            player.pause()
            await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            coordinator.close()
            XCTAssertEqual(item.isWatched, watched, "closed at \(position) s of 5 s")
            if !watched { XCTAssertEqual(try XCTUnwrap(item.playbackPosition), position, accuracy: 0.2) }
        }
    }

    private func makeEpisode(_ number: Int) throws -> DownloadItem {
        let name = "playback-episode-\(number)-\(UUID().uuidString).mp4"
        let file = DownloadStorage.libraryDirectory.appendingPathComponent(name)
        let source = try XCTUnwrap(FixtureSet.resourceURL(named: "fixture_captions.mp4", in: Bundle(for: LocalMediaServer.self)))
        try FileManager.default.copyItem(at: source, to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let item = DownloadItem(title: "Fixture Show Ep. \(number)", remoteURL: URL(string: "https://cdn.example/\(number).mp4")!,
                                sourcePageURL: URL(string: "https://site.example/watch?ep=\(number)")!, kind: .video, status: .completed)
        item.localFileName = name
        container.mainContext.insert(item)
        return item
    }

    func testTheEndOfAnEpisodePlaysTheNextInTheSamePlayer() async throws {
        let coordinator = makeCoordinator()
        let shows = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "PlaybackCoordinatorTests-\(UUID().uuidString)")!)
        coordinator.shows = shows
        let first = try makeEpisode(1), second = try makeEpisode(2)
        let show = shows.create(title: "Fixture Show", with: [first, second])

        coordinator.open(first, at: 0)
        try await waitUntil("episode 1 ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        let player = try XCTUnwrap(coordinator.controller.player)
        let firstItem = try XCTUnwrap(player.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: firstItem)
        try await waitUntil("episode 2 playing") { coordinator.title == "Fixture Show Ep. 2" && player.currentItem !== firstItem && !coordinator.isLoading }
        XCTAssertTrue(coordinator.controller.player === player, "the same player, so full screen or Picture in Picture carries on")
        XCTAssertTrue(first.isWatched)
        XCTAssertNotNil(second.lastPlayedAt)
        XCTAssertFalse(coordinator.isShowingUpNext)

        // The last episode ends the show.
        let secondItem = try XCTUnwrap(player.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: secondItem)
        try await waitUntil("episode 2 watched") { second.isWatched }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(player.currentItem === secondItem)

        // With autoplay off, the player stays on the finished episode.
        show.autoplayNext = false
        coordinator.open(first, at: 0)
        try await waitUntil("episode 1 ready again") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        let finished = try XCTUnwrap(coordinator.controller.player?.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: finished)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(coordinator.controller.player?.currentItem === finished)
        XCTAssertEqual(coordinator.title, "Fixture Show Ep. 1")
        coordinator.close()
    }

    /// A show of two episodes, with Delete Finished Episodes set as given.
    private func makeShow(deleting setting: FinishedEpisodes, for coordinator: PlaybackCoordinator) throws -> (ShowStore, Show, DownloadItem, DownloadItem) {
        let suite = "PlaybackCoordinatorTests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let shows = ShowStore(context: container.mainContext, preferences: preferences)
        let downloads = DownloadManager(context: container.mainContext, directConfiguration: .ephemeral, restore: false)
        downloads.preferences = preferences
        downloads.showStore = shows
        downloads.finishedEpisodes = setting
        coordinator.shows = shows
        coordinator.downloads = downloads
        let first = try makeEpisode(1), second = try makeEpisode(2)
        return (shows, shows.create(title: "Fixture Show", with: [first, second]), first, second)
    }

    private func closeNearTheEnd(_ coordinator: PlaybackCoordinator, at position: Double = 4.7) async throws {
        let player = try XCTUnwrap(coordinator.controller.player)
        player.pause()
        await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        coordinator.close()
    }

    private func exists(_ item: DownloadItem) throws -> Bool {
        FileManager.default.fileExists(atPath: try XCTUnwrap(item.localURL).path)
    }

    /// Delete Finished Episodes → Automatically: a finished episode is deleted once the player has
    /// moved on from it; videos outside a show are kept.
    func testFinishedEpisodesAreDeletedOnceThePlayerMovesOn() async throws {
        let coordinator = makeCoordinator()
        let (shows, show, first, second) = try makeShow(deleting: .delete, for: coordinator)
        let firstFile = try XCTUnwrap(first.localURL), secondFile = try XCTUnwrap(second.localURL)

        coordinator.open(first, at: 0)
        try await waitUntil("episode 1 ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: coordinator.controller.player?.currentItem)
        try await waitUntil("episode 2 playing") { coordinator.title == "Fixture Show Ep. 2" && !coordinator.isLoading }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path), "deleted once episode 2 took its place")
        XCTAssertEqual(shows.episodes(of: show).map(\.title), ["Fixture Show Ep. 2"])
        XCTAssertNotNil(show.deletedEpisodePlayedAt, "for Continue Watching")

        // Closed in its last 10%, the last episode goes too; the show stays, to follow new episodes.
        try await closeNearTheEnd(coordinator)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
        XCTAssertTrue(shows.episodes(of: show).isEmpty)
        XCTAssertEqual(shows.shows.map(\.title), ["Fixture Show"])

        let video = makeItem(in: container.mainContext)
        coordinator.open(video, at: 0)
        try await waitUntil("video ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        try await closeNearTheEnd(coordinator)
        XCTAssertTrue(video.isWatched)
        XCTAssertTrue(try exists(video), "not an episode of a show")
    }

    /// A finished episode marked for deletion and opened again stays.
    func testAFinishedEpisodeOpenedAgainIsKept() async throws {
        let coordinator = makeCoordinator()
        let (_, show, first, _) = try makeShow(deleting: .delete, for: coordinator)
        show.autoplayNext = false

        coordinator.open(first, at: 0)
        try await waitUntil("ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: coordinator.controller.player?.currentItem)
        try await waitUntil("watched") { first.isWatched }
        coordinator.open(first, at: 0)
        try await waitUntil("ready again") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        XCTAssertNil(coordinator.errorMessage)
        try await closeNearTheEnd(coordinator, at: 2.5)
        XCTAssertTrue(try exists(first), "closed halfway the second time")
    }

    /// Ask First: the player asks where Up Next appears. Off screen, as in Picture in Picture, it
    /// can't, so the episode stays and the next one plays; one closed in its last 10% is asked
    /// about once the player has gone.
    func testAskFirstKeepsUnansweredEpisodesAndAsksAfterClosing() async throws {
        let coordinator = makeCoordinator()
        let (_, _, first, second) = try makeShow(deleting: .ask, for: coordinator)

        coordinator.open(first, at: 0)
        try await waitUntil("episode 1 ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: coordinator.controller.player?.currentItem)
        try await waitUntil("episode 2 playing") { coordinator.title == "Fixture Show Ep. 2" && !coordinator.isLoading }
        XCTAssertTrue(try exists(first))
        XCTAssertNil(coordinator.finishedEpisode)

        try await closeNearTheEnd(coordinator)
        XCTAssertTrue(coordinator.finishedEpisode === second)
        coordinator.answerFinishedEpisode(delete: false)
        XCTAssertNil(coordinator.finishedEpisode)
        XCTAssertTrue(try exists(second))

        coordinator.open(first, at: 0)
        try await waitUntil("episode 1 ready again") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        try await closeNearTheEnd(coordinator, at: 2.5)
        XCTAssertNil(coordinator.finishedEpisode, "closed halfway")

        coordinator.open(second, at: 0)
        try await waitUntil("episode 2 ready again") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        try await closeNearTheEnd(coordinator)
        let secondFile = try XCTUnwrap(second.localURL)
        coordinator.answerFinishedEpisode(delete: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
        XCTAssertTrue(try exists(first))
    }

    func testIntroIsSkippedCreditsCountAsWatchedAndSpeedIsKept() async throws {
        let coordinator = makeCoordinator()
        let shows = ShowStore(context: container.mainContext, preferences: UserDefaults(suiteName: "PlaybackCoordinatorTests-\(UUID().uuidString)")!)
        coordinator.shows = shows
        let first = try makeEpisode(1), second = try makeEpisode(2)
        let show = shows.create(title: "Fixture Show", with: [first, second])
        show.introStart = 1
        show.introEnd = 3
        show.creditsFromEnd = 1
        show.autoSkipIntro = true
        show.playbackRate = 1.5

        coordinator.open(first, at: 0)
        try await waitUntil("ready") { coordinator.controller.player?.currentItem != nil && !coordinator.isLoading }
        XCTAssertEqual(coordinator.controller.selectedSpeed?.rate, 1.5, "the show's speed is applied")
        let player = try XCTUnwrap(coordinator.controller.player)
        player.pause()
        coordinator.showPlaybackTick(at: 1.2)
        try await waitUntil("skipped past the intro") { player.currentTime().seconds >= 2.9 }
        XCTAssertFalse(first.isWatched)
        coordinator.showPlaybackTick(at: 4.2)
        XCTAssertTrue(first.isWatched, "the credits count as the end")

        // Next and previous episode, as from the Lock Screen.
        XCTAssertTrue(coordinator.playEpisode(1))
        try await waitUntil("episode 2") { coordinator.title == "Fixture Show Ep. 2" && !coordinator.isLoading }
        XCTAssertTrue(coordinator.controller.player === player)
        XCTAssertFalse(coordinator.playEpisode(1), "no episode after the last")
        XCTAssertTrue(coordinator.playEpisode(-1))
        try await waitUntil("back to episode 1") { coordinator.title == "Fixture Show Ep. 1" && !coordinator.isLoading }
        coordinator.close()
    }
}
