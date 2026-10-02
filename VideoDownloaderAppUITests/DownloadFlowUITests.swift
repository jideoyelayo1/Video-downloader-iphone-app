import XCTest

/// Browse → detect → download → library → playback, against pages served by `LocalMediaServer` from the test runner.
final class DownloadFlowUITests: XCTestCase {
    private var server: LocalMediaServer!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try LocalMediaServer()
        try server.start()
        app = XCUIApplication()
    }

    override func tearDown() {
        app?.terminate()
        server?.stop()
    }

    private func launch(at path: String) {
        app.launchArguments = ["-UITestInMemory", "-StartURL", server.url(path).absoluteString]
        app.launch()
        app.tabBars.buttons["Browse"].tap()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        // Tap at the trailing edge so the cursor starts after the existing text.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 5) + text)
    }

    /// Waits until the Found videos button reports at least `count` validated candidates.
    @discardableResult
    private func waitForReadyCandidates(_ count: Int, timeout: TimeInterval = 20) -> XCUIElement {
        let button = app.buttons["browser.foundVideos"]
        let predicate = NSPredicate { _, _ in (button.value as? String).flatMap { Int($0.split(separator: " ").first ?? "") }.map { $0 >= count } ?? false }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Found videos value: \(String(describing: button.value))")
        return button
    }

    /// Downloads the page's first ready video and waits for it to complete.
    private func downloadFirstCandidate() {
        waitForReadyCandidates(1).tap()
        app.buttons["candidate.download"].firstMatch.tap()
        let status = app.staticTexts.matching(identifier: "download.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let completed = NSPredicate(format: "label BEGINSWITH 'Completed'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: status)], timeout: 30), .completed, status.label)
    }

    private func wait(for element: XCUIElement, _ format: String, timeout: TimeInterval = 10, _ message: @autoclosure () -> String = "") {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message())
    }

    /// AVKit toggles its controls on a tap, so tap until they are showing.
    private func revealPlayerControls() {
        let close = app.buttons["Close"]
        for _ in 0..<4 {
            if close.exists && close.isHittable { return }
            app.otherElements["player.video"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: close)], timeout: 2)
        }
        XCTAssertTrue(close.isHittable, "AVKit's controls should appear after a tap")
    }

    /// Closes the player with AVKit's own close button, the only way out.
    private func closePlayer() {
        revealPlayerControls()
        app.buttons["Close"].tap()
        wait(for: app.otherElements["player.video"], "exists == false", timeout: 5, "the player should close")
    }

    /// AVKit's Off item: identified on iOS 26 (beside On (Language)), labelled on iOS 18
    /// (beside Auto (Recommended) and the languages).
    private var subtitlesOffItem: XCUIElement {
        let identified = app.buttons["AVSubtitlesOffAction"]
        return identified.exists ? identified : app.buttons.matching(NSPredicate(format: "label == 'Off'")).firstMatch
    }

    private func openSubtitlesMenu() {
        revealPlayerControls()
        app.buttons["More Controls"].tap()
        let subtitles = app.buttons["Subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        subtitles.tap()
        XCTAssertTrue(subtitlesOffItem.waitForExistence(timeout: 5))
    }

    func testBrowseDetectDownloadPlayExportRenameDelete() throws {
        launch(at: "/page/basic.html")
        waitForReadyCandidates(1).tap()

        let download = app.buttons["candidate.download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.isEnabled)
        download.tap()

        // Starting a download switches to the Downloads tab.
        let status = app.staticTexts.matching(identifier: "download.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let completed = NSPredicate(format: "label BEGINSWITH 'Completed'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: status)], timeout: 20), .completed, status.label)
        XCTAssertTrue(status.label.hasPrefix("Completed today at "), status.label)

        app.tabBars.buttons["My Videos"].tap()
        let libraryItem = app.buttons["library.item"].firstMatch
        XCTAssertTrue(libraryItem.waitForExistence(timeout: 5))
        XCTAssertTrue(libraryItem.label.contains("Basic Video Page"), libraryItem.label)
        XCTAssertTrue(libraryItem.label.contains("Downloaded today at "), libraryItem.label)

        // Playback
        libraryItem.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))
        revealPlayerControls()
        // One way out, AVKit's own, and no second Done button of the app's.
        XCTAssertEqual(app.buttons.matching(identifier: "Close Button").count, 1)
        XCTAssertFalse(app.buttons["player.done"].exists)
        closePlayer()
        libraryItem.press(forDuration: 1.2)
        let export = app.buttons["Export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.sheets.firstMatch.waitForExistence(timeout: 2),
                      "share sheet should appear")
        // iOS 18 presents a sheet (swipe down); iOS 26 a popover (tap outside).
        let shareSheet = app.otherElements["ActivityListView"]
        let closeShare = app.buttons["Close"].firstMatch
        if closeShare.waitForExistence(timeout: 3) { closeShare.tap() } else { app.swipeDown(velocity: .fast) }
        // Give the swipe time to finish; tapping too early can hit "Edit Actions…" inside the sheet.
        if !shareSheet.waitForNonExistence(timeout: 3) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: libraryItem)], timeout: 5), .completed)

        // Rename
        app.buttons["library.moreOptions"].firstMatch.tap()
        app.buttons["Rename"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(in: field, with: "Renamed episode")
        app.alerts.buttons["Save"].tap()
        let renamed = app.buttons["library.item"].firstMatch
        let hasNewTitle = NSPredicate(format: "label CONTAINS 'Renamed episode'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hasNewTitle, object: renamed)], timeout: 5), .completed, renamed.label)

        // Delete
        app.buttons["library.item"].firstMatch.press(forDuration: 1.2)
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 5))
    }

    func testDetectsDynamicallyInsertedAndIframePlayers() throws {
        launch(at: "/page/dynamic.html")
        waitForReadyCandidates(1)

        app.buttons["browser.bookmarks"].tap()
        XCTAssertTrue(app.staticTexts["***REMOVED***"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["***REMOVED***"].exists)
        XCTAssertTrue(app.staticTexts["***REMOVED***"].exists)
        XCTAssertTrue(app.staticTexts["***REMOVED***"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Lanterns S1E1'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Add This Page"].waitForExistence(timeout: 5))
        app.buttons["Add This Page"].tap()
        app.buttons["Done"].tap()

        let address = app.textFields["browser.address"]
        app.buttons["Clear address"].tap()
        address.tap()
        address.typeText(server.url("/page/iframe.html").absoluteString + "\n")
        let button = waitForReadyCandidates(1)
        button.tap()
        XCTAssertTrue(app.buttons["candidate.download"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "candidate.download").count, 1, "navigating clears the previous page's candidates")
    }

    func testBrowserHistoryRecordsAndClearsVisitedPage() throws {
        launch(at: "/page/basic.html")
        XCTAssertTrue(app.buttons["browser.foundVideos"].waitForExistence(timeout: 10))
        app.buttons["browser.bookmarks"].tap()
        app.segmentedControls.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history.page"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history.page"].firstMatch.label.contains("Basic Video Page"))
        app.buttons["history.clearAll"].tap()
        app.buttons["Clear All History"].tap()
        XCTAssertTrue(app.staticTexts["No history yet"].waitForExistence(timeout: 5))
    }

    func testSamePageNavigationUpdatesAddressTitleAndBack() throws {
        launch(at: "/page/spa.html")
        let address = app.textFields["browser.address"]
        let back = app.buttons["Back"]
        let link = app.webViews.links["Next episode"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertFalse(back.isEnabled)
        link.tap()
        let moved = NSPredicate(format: "value ENDSWITH '/page/spa.html?ep=2'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: address)], timeout: 10), .completed,
                       String(describing: address.value))
        XCTAssertTrue(app.navigationBars["SPA Episode 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(back.isEnabled)
        back.tap()
        let returned = NSPredicate(format: "value ENDSWITH '/page/spa.html'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: address)], timeout: 10), .completed,
                       String(describing: address.value))
    }

    func testHLSStreamIsValidatedWithQualityChoices() throws {
        launch(at: "/page/hls.html")
        waitForReadyCandidates(1).tap()
        let download = app.buttons["candidate.download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'HLS stream'")).firstMatch.exists)
        // HLS offline downloads need a physical device; here we only check the quality menu.
        download.tap()
        XCTAssertTrue(app.buttons["360p"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["180p"].exists)
    }

    func testSeparateAudioPlaylistIsNotOfferedAsAVideo() throws {
        launch(at: "/page/separate-audio.html")
        waitForReadyCandidates(1).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Master playlist'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "candidate.download").count, 1)
        XCTAssertFalse(app.otherElements["candidate.audio-only.m3u8"].exists)
    }

    /// Built-in caption tracks use AVKit's own subtitle menu; turning them off there is remembered.
    func testCaptionChoiceIsRememberedForTheNextPlayback() throws {
        launch(at: "/page/captions.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))
        openSubtitlesMenu()
        // The first playback turns captions on.
        XCTAssertFalse(subtitlesOffItem.isSelected)
        subtitlesOffItem.tap()
        closePlayer()

        item.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))
        openSubtitlesMenu()
        XCTAssertTrue(subtitlesOffItem.isSelected, "captions turned off should stay off")
        subtitlesOffItem.tap()
        closePlayer()
    }

    /// ***REMOVED***-style subtitles (separate <track> files) are saved with the download and shown over the saved video.
    func testSiteSubtitlesAreSavedAndShownInTheSavedVideo() throws {
        launch(at: "/page/tracks.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let subtitle = app.staticTexts["player.subtitle"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        XCTAssertEqual(subtitle.label, "Fixture English line")

        // The subtitles button appears with AVKit's controls.
        revealPlayerControls()
        let button = app.buttons["player.captions"]
        XCTAssertTrue(button.isHittable)
        XCTAssertEqual(button.value as? String, "English")
        button.tap()
        XCTAssertTrue(app.buttons["Español"].waitForExistence(timeout: 5))
        app.buttons["Español"].tap()
        wait(for: subtitle, "label == 'Línea de prueba & más'", timeout: 5, subtitle.label)

        // Landscape keeps the subtitle on the picture.
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        sleep(1)
        XCTAssertTrue(subtitle.exists)
        let frame = subtitle.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCUIDevice.shared.orientation = .portrait
        sleep(1)

        revealPlayerControls()
        button.tap()
        XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 5))
        app.buttons["Off"].tap()
        wait(for: subtitle, "exists == false", timeout: 5)
        closePlayer()
    }

    /// A 60-second video with one subtitle line per 10 s, so the line shown tells where playback is.
    func testWatchedAtTheEndAndByHand() throws {
        launch(at: "/page/basic.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertFalse(item.label.contains("Watched"), item.label)

        // The 5-second video plays to the end.
        item.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))
        sleep(7)
        closePlayer()
        wait(for: item, "label CONTAINS 'Watched'", timeout: 5, item.label)

        app.buttons["library.moreOptions"].firstMatch.tap()
        app.buttons["Mark as Unwatched"].tap()
        wait(for: item, "NOT (label CONTAINS 'Watched')", timeout: 5, item.label)

        item.swipeRight()
        app.buttons["Watched"].tap()
        wait(for: item, "label CONTAINS 'Watched'", timeout: 5, item.label)
    }

    func testSiteLabelAndLabelsFromTheMenu() throws {
        launch(at: "/page/basic.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        // The test server's site has no name, so its label is its address.
        XCTAssertTrue(item.label.contains("Labels: 127.0.0.1"), item.label)

        app.buttons["library.moreOptions"].firstMatch.tap()
        app.buttons["Labels"].tap()
        app.buttons["New Label…"].tap()
        let alert = app.alerts["New Label"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("Favourites")
        alert.buttons["Add"].tap()
        wait(for: item, "label CONTAINS 'Favourites'", timeout: 5, item.label)

        app.buttons["library.folders"].tap()
        app.buttons["Manage Labels"].tap()
        let favourites = app.cells.containing(.staticText, identifier: "Favourites").firstMatch
        XCTAssertTrue(favourites.waitForExistence(timeout: 5))
        favourites.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Done"].tap()
        wait(for: item, "NOT (label CONTAINS 'Favourites')", timeout: 5, item.label)
        XCTAssertTrue(item.label.contains("Basic Video Page"), "deleting a label keeps its videos")
    }

    func testResumeSeekAndContinueWatching() throws {
        launch(at: "/page/long.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let subtitle = app.staticTexts["player.subtitle"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        XCTAssertEqual(subtitle.label, "Zero to ten")
        wait(for: subtitle, "label == 'Ten to twenty'", timeout: 15, subtitle.label)
        sleep(2)
        closePlayer()

        // Watched past 10 s: the video is offered under Continue Watching and resumes where it stopped.
        // iOS 18 shows list headers in capitals.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Continue Watching'")).firstMatch.waitForExistence(timeout: 5))
        wait(for: item, "label CONTAINS 'Continue watching'", timeout: 5, item.label)
        item.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        app.buttons["Resume"].tap()
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        XCTAssertEqual(subtitle.label, "Ten to twenty", "should resume near 12 s, not from the start")

        // Seeking with AVKit's controls moves the subtitle with it. Paused, so the position is exact:
        // about 12 s, +20 s, then -10 s.
        revealPlayerControls()
        app.buttons["Play/Pause"].tap()
        app.buttons["Skip Forward"].tap()
        app.buttons["Skip Forward"].tap()
        wait(for: subtitle, "label == 'Thirty to forty'", timeout: 5, subtitle.label)
        revealPlayerControls()
        app.buttons["Skip Backward"].tap()
        wait(for: subtitle, "label == 'Twenty to thirty'", timeout: 5, subtitle.label)
        closePlayer()

        item.tap()
        XCTAssertTrue(app.buttons["Start from Beginning"].waitForExistence(timeout: 5))
        app.buttons["Start from Beginning"].tap()
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        XCTAssertEqual(subtitle.label, "Zero to ten")
        closePlayer()
    }

    func testFragmentIsExplainedWithoutDownloadButton() throws {
        launch(at: "/page/fragment.html")
        let button = app.buttons["browser.foundVideos"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.staticTexts["Stream pieces found"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.download"].exists)
    }

    func testRefererProtectedHLSIsOfferedThroughRelay() throws {
        launch(at: "/page/referer-hls.html")
        waitForReadyCandidates(1).tap()
        let download = app.buttons["candidate.download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'keep app open'")).firstMatch.exists)
    }

    func testLibraryCanCreateFolderAndSearchDownloadedVideo() throws {
        launch(at: "/page/basic.html")
        waitForReadyCandidates(1).tap()
        app.buttons["candidate.download"].firstMatch.tap()
        let status = app.staticTexts.matching(identifier: "download.status").firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Completed'"), object: status)], timeout: 20), .completed)
        XCTAssertTrue(app.staticTexts["Downloads used"].exists)
        XCTAssertTrue(app.staticTexts["Available on iPhone"].exists)

        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        app.buttons["library.folders"].tap()
        app.buttons["New Folder"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Anime")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["No matching videos"].waitForExistence(timeout: 5))
        app.buttons["library.folders"].tap()
        app.buttons["All Videos"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("not this episode")
        XCTAssertTrue(app.staticTexts["No matching videos"].waitForExistence(timeout: 5))
    }
}
