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

    /// `keepOverlay`: site subtitles stay drawn by the app, whose text tells where playback is,
    /// instead of moving into the video file.
    /// Added to the next launch, for one test's needs.
    private var extraLaunchArguments: [String] = []

    private func launch(at path: String, keepOverlay: Bool = true) {
        app.launchArguments = ["-UITestInMemory", "-StartURL", server.url(path).absoluteString] + (keepOverlay ? ["-KeepSiteSubtitleOverlay"] : [])
            + extraLaunchArguments
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

    private func openPage(_ path: String) {
        app.tabBars.buttons["Browse"].tap()
        let address = app.textFields["browser.address"]
        app.buttons["Clear address"].tap()
        address.tap()
        address.typeText(server.url(path).absoluteString + "\n")
    }

    /// Two 5-second videos: "Basic Video Page", then "Captioned Video Page". Ends in My Videos.
    private func downloadBasicAndCaptioned() {
        launch(at: "/page/basic.html")
        downloadFirstCandidate()
        openPage("/page/captions.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let items = app.buttons.matching(identifier: "library.item")
        wait(for: items.element(boundBy: 1), "exists == true", timeout: 5, "both videos are listed")
    }

    private var libraryTitles: [String] {
        app.buttons.matching(identifier: "library.item").allElementsBoundByIndex.map { item in
            ["Basic Video Page", "Captioned Video Page"].first { item.label.contains($0) } ?? item.label
        }
    }

    private func renameVideo(at index: Int, to title: String) {
        app.buttons.matching(identifier: "library.moreOptions").element(boundBy: index).tap()
        app.buttons["Rename"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(in: field, with: title)
        app.alerts.buttons["Save"].tap()
        wait(for: app.buttons.matching(identifier: "library.item").element(boundBy: index), "label CONTAINS %@".replacingOccurrences(of: "%@", with: "'\(title)'"),
             timeout: 5, "renamed to \(title)")
    }

    /// The two 5-second videos as episodes 1 and 2 of "Fixture Show", made into a show from its suggestion.
    private func makeTwoEpisodeShow() {
        downloadBasicAndCaptioned()
        renameVideo(at: 1, to: "Fixture Show Ep. 1")
        renameVideo(at: 0, to: "Fixture Show Ep. 2")
        let create = app.buttons["Create Show"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "two episodes of one series are suggested as a show")
        create.tap()
        let name = app.textFields["newShow.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Fixture Show")
        app.navigationBars.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["library.show"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Where a player control is, if it's showing. AVKit's controls fade in and out, and reading a
    /// vanished control's `frame` or `isHittable` fails the test, while a snapshot only throws.
    /// Since Xcode 27, hidden controls can also stay in the tree with an infinite frame.
    private func shownFrame(of element: XCUIElement) -> CGRect? {
        guard let frame = try? element.snapshot().frame,
              frame.minX.isFinite, frame.minY.isFinite, !frame.isEmpty else { return nil }
        return frame
    }

    /// A tap at a control's position, not on the element: if the controls hid first, the tap only
    /// shows them again instead of failing the test.
    private func tap(at frame: CGRect) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    /// AVKit toggles its controls on a tap, so tap until they are showing.
    private func revealPlayerControls() {
        let close = app.buttons["Close"]
        let showing = NSPredicate { [unowned self] _, _ in shownFrame(of: close) != nil }
        for _ in 0..<4 {
            if shownFrame(of: close) != nil { return }
            app.otherElements["player.video"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: showing, object: nil)], timeout: 2)
        }
        XCTAssertNotNil(shownFrame(of: close), "AVKit's controls should appear after a tap")
    }

    /// Taps a control that shows and hides with AVKit's (they hide about 2 s after appearing),
    /// trying again if they hid first.
    private func tapPlayerControl(_ control: XCUIElement, opening result: XCUIElement) {
        for _ in 0..<3 {
            revealPlayerControls()
            if let frame = shownFrame(of: control) { tap(at: frame) }
            if result.waitForExistence(timeout: 2) { return }
        }
        XCTFail("\(control) didn't open \(result)")
    }

    /// Closes the player with AVKit's own close button, the only way out, the same way.
    private func closePlayer() {
        let video = app.otherElements["player.video"]
        for _ in 0..<3 {
            revealPlayerControls()
            if let frame = shownFrame(of: app.buttons["Close"]) { tap(at: frame) }
            if video.waitForNonExistence(timeout: 3) { return }
        }
        XCTFail("the player should close")
    }

    /// AVKit's Off item: identified on iOS 26 (beside On (Language)), labelled on iOS 18
    /// (beside Auto (Recommended) and the languages).
    private var subtitlesOffItem: XCUIElement {
        let identified = app.buttons["AVSubtitlesOffAction"]
        return identified.exists ? identified : app.buttons.matching(NSPredicate(format: "label == 'Off'")).firstMatch
    }

    private func openSubtitlesMenu() {
        let subtitles = app.buttons["Subtitles"]
        tapPlayerControl(app.buttons["More Controls"], opening: subtitles)
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
        // Browse Only, the last folder, can be below the fold.
        let ***REMOVED*** = app.staticTexts["***REMOVED***"]
        for _ in 0..<3 where !***REMOVED***.exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["***REMOVED***"].exists)
        XCTAssertTrue(***REMOVED***.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Lanterns S1E1'")).firstMatch.exists)
        for _ in 0..<3 where !app.buttons["Add This Page"].exists { app.swipeDown() }
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
        // Each quality carries its estimated size: "360p · about 563 KB".
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '360p · about '")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '180p · about '")).firstMatch.exists)
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
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertEqual(button.value as? String, "English")
        tapPlayerControl(button, opening: app.buttons["Español"])
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

        tapPlayerControl(button, opening: app.buttons["Off"])
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

    func testSortAndFilter() throws {
        downloadBasicAndCaptioned()
        XCTAssertEqual(libraryTitles, ["Captioned Video Page", "Basic Video Page"], "newest first")
        let menu = app.buttons["library.sortFilter"]
        menu.tap()
        app.buttons["Oldest Downloads"].tap()
        wait(for: app.buttons["library.item"].firstMatch, "label CONTAINS 'Basic Video Page'", timeout: 5, libraryTitles.joined(separator: ", "))

        // Watched filter, shown as a removable chip.
        app.buttons.matching(identifier: "library.moreOptions").element(boundBy: 0).tap()
        app.buttons["Mark as Watched"].tap()
        menu.tap()
        app.buttons["Unwatched"].tap()
        let chip = app.buttons["Remove filter: Unwatched"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(libraryTitles, ["Captioned Video Page"])
        chip.tap()
        wait(for: app.buttons.matching(identifier: "library.item").element(boundBy: 1), "exists == true", timeout: 5, "both listed again")

        // A label filter.
        app.buttons.matching(identifier: "library.moreOptions").element(boundBy: 1).tap()
        app.buttons["Labels"].tap()
        app.buttons["New Label…"].tap()
        app.alerts["New Label"].textFields.firstMatch.typeText("Keep")
        app.alerts["New Label"].buttons["Add"].tap()
        menu.tap()
        app.buttons["Keep"].tap()
        XCTAssertTrue(app.buttons["Remove filter: Keep"].waitForExistence(timeout: 5))
        XCTAssertEqual(libraryTitles, ["Captioned Video Page"])
        menu.tap()
        app.buttons["Clear Filters"].tap()
        wait(for: app.buttons.matching(identifier: "library.item").element(boundBy: 1), "exists == true", timeout: 5, "filters cleared")
    }

    func testShowFromSuggestionKeepsTheViewersOrder() throws {
        makeTwoEpisodeShow()
        let show = app.buttons["library.show"].firstMatch
        XCTAssertTrue(show.label.contains("Fixture Show") && show.label.contains("0 of 2 watched"), show.label)
        XCTAssertFalse(app.buttons["Create Show"].exists, "the suggestion is gone once the show exists")
        show.tap()

        let episodes = app.buttons.matching(identifier: "show.episode")
        wait(for: episodes.element(boundBy: 1), "exists == true", timeout: 5, "both episodes listed")
        XCTAssertTrue(episodes.element(boundBy: 0).label.contains("Ep. 1"), episodes.element(boundBy: 0).label)
        XCTAssertTrue(app.buttons["show.playNext"].label.contains("Play Ep. 1"), app.buttons["show.playNext"].label)

        // Drag episode 2 above episode 1.
        app.buttons["Edit"].tap()
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        wait(for: handles.element(boundBy: 1), "exists == true", timeout: 5, "reorder handles")
        handles.element(boundBy: 1).press(forDuration: 0.6, thenDragTo: handles.element(boundBy: 0))
        app.buttons["Done"].tap()
        wait(for: episodes.element(boundBy: 0), "label CONTAINS 'Ep. 2'", timeout: 5, episodes.element(boundBy: 0).label)

        app.buttons["show.options"].tap()
        app.buttons["Order by Episode Number"].tap()
        wait(for: episodes.element(boundBy: 0), "label CONTAINS 'Ep. 1'", timeout: 5, episodes.element(boundBy: 0).label)
    }

    func testSleepTimerMenuShowsCountdownChangesAndCancels() throws {
        launch(at: "/page/long.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        app.buttons["library.item"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))
        // Paused playback keeps AVKit's controls visible while we inspect their values.
        // The sleep countdown must still advance while the video is paused.
        tapPlayerControl(app.buttons["Pause"], opening: app.buttons["Play"])
        let timer = app.buttons["player.sleepTimer"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertEqual(timer.value as? String, "Off")
        tapPlayerControl(timer, opening: app.buttons["10 minutes"])
        for minutes in [10, 15, 20, 30, 45, 60] {
            XCTAssertTrue(app.buttons["\(minutes) minutes"].exists)
        }
        XCTAssertTrue(app.buttons["End of video"].exists)
        app.buttons["10 minutes"].tap()
        wait(for: timer, "value MATCHES '9:[0-5][0-9]'", timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Sleep timer countdown"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        tapPlayerControl(timer, opening: app.buttons["20 minutes"])
        app.buttons["20 minutes"].tap()
        wait(for: timer, "value MATCHES '19:[0-5][0-9]'", timeout: 5)
        tapPlayerControl(timer, opening: app.buttons["Turn Off Timer"])
        app.buttons["Turn Off Timer"].tap()
        XCTAssertEqual(timer.value as? String, "Off")

        tapPlayerControl(timer, opening: app.buttons["End of video"])
        app.buttons["End of video"].tap()
        XCTAssertEqual(timer.value as? String, "End of video")
        closePlayer()
        app.buttons["library.item"].firstMatch.tap()
        XCTAssertTrue(timer.waitForExistence(timeout: 10))
        XCTAssertEqual(timer.value as? String, "Off", "closing clears the session's sleep timer")
        closePlayer()
    }

    func testShowPlaysTheNextEpisodeAfterACountdown() throws {
        makeTwoEpisodeShow()
        app.buttons["library.show"].firstMatch.tap()
        XCTAssertTrue(app.switches["show.autoplay"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["show.autoplay"].value as? String, "1", "autoplay is on for new shows")
        app.buttons["show.playNext"].tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))

        // Episode 1 (5 s) ends: the Up Next countdown appears, then episode 2 plays in the same player.
        let playNow = app.buttons["player.upNext.play"]
        XCTAssertTrue(playNow.waitForExistence(timeout: 15), "Up Next appears when episode 1 ends")
        XCTAssertTrue(app.staticTexts["Fixture Show Ep. 2"].exists)
        wait(for: playNow, "exists == false", timeout: 8, "the countdown starts episode 2")
        XCTAssertTrue(app.otherElements["player.video"].exists, "the player stays open")

        // Episode 2 is the last: no Up Next after it.
        sleep(7)
        XCTAssertFalse(app.buttons["player.upNext.play"].exists)
        closePlayer()
        // "2 of 2 watched · 460 KB".
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of 2 watched'")).firstMatch.waitForExistence(timeout: 5))
    }

    /// The intro is marked once from the player, then offered as Skip Intro on the next viewing.
    func testIntroMarkedInThePlayerIsSkipped() throws {
        launch(at: "/page/long.html")
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        // A show of one video, made from its menu.
        app.buttons["library.moreOptions"].firstMatch.tap()
        app.buttons["Add to Show"].tap()
        app.buttons["New Show…"].firstMatch.tap()
        let name = app.textFields["newShow.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Create"].tap()

        item.tap()
        let subtitle = app.staticTexts["player.subtitle"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        let episode = app.buttons["player.episode"]
        wait(for: subtitle, "label == 'Ten to twenty'", timeout: 15, subtitle.label)
        tapPlayerControl(episode, opening: app.buttons["Intro Starts Here"])
        app.buttons["Intro Starts Here"].tap()
        wait(for: subtitle, "label == 'Twenty to thirty'", timeout: 15, subtitle.label)
        tapPlayerControl(episode, opening: app.buttons["Intro Ends Here"])
        app.buttons["Intro Ends Here"].tap()
        // Opening the menu can take several seconds, so the end is somewhere after 0:20.
        let cues = ["Zero to ten", "Ten to twenty", "Twenty to thirty", "Thirty to forty", "Forty to fifty", "Fifty to sixty"]
        let endCue = subtitle.label
        XCTAssertTrue(cues.contains(endCue), endCue)
        closePlayer()

        item.tap()
        // Closed before the end, it offers to resume. When the menu was slow, the player can
        // close in the last seconds, which counts as watched: it then starts again by itself.
        let restart = app.buttons["Start from Beginning"]
        if restart.waitForExistence(timeout: 5) { restart.tap() }
        let skip = app.buttons["player.skipIntro"]
        // The intro was marked to start some seconds after 0:10, depending on how long the menu took.
        XCTAssertTrue(skip.waitForExistence(timeout: 45), "Skip Intro appears once the intro starts")
        skip.tap()
        // Playback goes on from the end mark: its cue, or the next one if the mark was near the cue's end.
        let landing = cues.drop { $0 != endCue }.prefix(2).map { "'\($0)'" }.joined(separator: ", ")
        wait(for: subtitle, "label IN {\(landing)}", timeout: 5, subtitle.label)
        XCTAssertFalse(skip.exists)
        closePlayer()
    }

    /// Site subtitles move into a direct download, so iOS lists them itself (and shows them in
    /// Picture in Picture), instead of the app's separate Subtitles button.
    func testSiteSubtitlesMoveIntoTheVideoFile() throws {
        launch(at: "/page/tracks.html", keepOverlay: false)
        downloadFirstCandidate()
        app.tabBars.buttons["My Videos"].tap()
        let item = app.buttons["library.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        sleep(2)
        item.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertFalse(app.buttons["player.captions"].exists, "no separate button: the subtitles are in the video")
        openSubtitlesMenu()
        // iOS 26 lists the languages under Language; iOS 18 lists them beside Off.
        let languages = app.buttons["AVLanguagesMenu"]
        if languages.exists { languages.tap() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Spanish'")).firstMatch.waitForExistence(timeout: 5),
                      "iOS lists the site's languages")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Spanish'")).firstMatch.tap()
        closePlayer()
    }

    func testNextEpisodesDownloadFromFoundVideos() throws {
        launch(at: "/series/ep-1.html")
        waitForReadyCandidates(1).tap()
        let download = app.buttons["season.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5), "numbered episode pages offer the next episodes")
        XCTAssertTrue(app.staticTexts["Next 3 episodes"].exists)
        download.tap()
        let status = app.staticTexts["season.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        wait(for: status, "label BEGINSWITH 'Queued 2 episodes'", timeout: 60, status.label)
        let statuses = app.staticTexts.matching(identifier: "download.status")
        wait(for: statuses.element(boundBy: 1), "label BEGINSWITH 'Completed'", timeout: 30, "episode downloads complete")
        XCTAssertTrue(app.staticTexts["Fixture Series Ep. 2"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Series Ep. 3"].exists)
    }

    func testDeleteAShowsWatchedEpisodes() throws {
        makeTwoEpisodeShow()
        app.buttons["library.show"].firstMatch.tap()
        let episodes = app.buttons.matching(identifier: "show.episode")
        wait(for: episodes.element(boundBy: 1), "exists == true", timeout: 5, "both episodes")
        episodes.element(boundBy: 0).swipeRight()
        app.buttons["Watched"].tap()
        app.buttons["show.options"].tap()
        let delete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete Watched Episodes (1'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        app.buttons["Delete Watched Episodes"].tap()
        wait(for: episodes.element(boundBy: 1), "exists == false", timeout: 5, "the watched episode is deleted")
        XCTAssertTrue(episodes.element(boundBy: 0).label.contains("Ep. 2"), episodes.element(boundBy: 0).label)
    }

    /// A watched episode has its own Delete button, which asks first; any episode's menu can delete it too.
    func testDeleteOneEpisodeAfterConfirming() throws {
        makeTwoEpisodeShow()
        app.buttons["library.show"].firstMatch.tap()
        let episodes = app.buttons.matching(identifier: "show.episode")
        wait(for: episodes.element(boundBy: 1), "exists == true", timeout: 5, "both episodes")
        let delete = app.buttons.matching(identifier: "show.deleteEpisode")
        XCTAssertEqual(delete.count, 0, "only watched episodes have the button")
        episodes.element(boundBy: 0).swipeRight()
        app.buttons["Watched"].tap()
        XCTAssertTrue(delete.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(delete.count, 1)

        delete.firstMatch.tap()
        let alert = app.alerts["Delete this episode?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "it asks first")
        alert.buttons["Cancel"].tap()
        wait(for: alert, "exists == false", timeout: 5, "cancelled")
        XCTAssertEqual(episodes.count, 2, "nothing deleted")

        delete.firstMatch.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        wait(for: episodes.element(boundBy: 1), "exists == false", timeout: 5, "episode 1 deleted")
        XCTAssertTrue(episodes.element(boundBy: 0).label.contains("Ep. 2"), episodes.element(boundBy: 0).label)

        // An unwatched episode, from its menu.
        episodes.element(boundBy: 0).press(forDuration: 1.2)
        app.buttons["Delete Episode…"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        wait(for: episodes.element(boundBy: 0), "exists == false", timeout: 5, "episode 2 deleted")
        app.navigationBars.buttons["My Videos"].tap()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 5), "the videos are gone from My Videos too")
    }

    /// A show's menu, or a swipe on it in My Videos, deletes it with or without its episodes.
    /// (iOS 26's dialogs have no Cancel button, so each one is answered.)
    func testDeleteAShowAndItsEpisodes() throws {
        makeTwoEpisodeShow()
        let show = app.buttons["library.show"].firstMatch
        show.tap()
        app.buttons["show.options"].tap()
        app.buttons["Delete Show…"].tap()
        let deleteAll = app.buttons["Delete Show and Episodes"]
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Deleting its episodes removes 2 videos'")).firstMatch.exists)
        app.buttons["Delete Show Only"].tap()
        let items = app.buttons.matching(identifier: "library.item")
        wait(for: items.element(boundBy: 1), "exists == true", timeout: 5, "back in My Videos, with both videos kept")
        XCTAssertFalse(show.exists)

        // The videos are offered as a show again; made into one, a swipe deletes it with them.
        let create = app.buttons["Create Show"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        XCTAssertTrue(app.textFields["newShow.name"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Create"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(deleteAll.waitForExistence(timeout: 5))
        deleteAll.tap()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 5), "the episodes went with the show")
        XCTAssertFalse(show.exists)
    }

    /// Settings → Delete Finished Episodes → Ask First: the end card has a Delete box beside
    /// Next Episode, applied when the card goes, and an episode deleted there leaves the show.
    func testFinishedEpisodeIsDeletedWhenTickedOnTheEndCard() throws {
        // XCUITest can take longer than the card's 10 seconds to find and tap the box.
        extraLaunchArguments = ["-UpNextSeconds", "120"]
        makeTwoEpisodeShow()
        app.tabBars.buttons["Settings"].tap()
        let setting = app.buttons["settings.finishedEpisodes"]
        for _ in 0..<4 where !(setting.exists && setting.isHittable) { app.swipeUp() }
        setting.tap()
        let askFirst = app.buttons["Ask First"]
        XCTAssertTrue(askFirst.waitForExistence(timeout: 5))
        askFirst.tap()
        wait(for: setting, "label CONTAINS 'Ask First' OR value CONTAINS 'Ask First'", timeout: 5, setting.debugDescription)

        app.tabBars.buttons["My Videos"].tap()
        app.buttons["library.show"].firstMatch.tap()
        app.buttons["show.playNext"].tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 10))

        // Episode 1 (5 s) ends: one card with Next Episode and an unticked Delete box.
        let toggle = app.buttons["player.deleteEpisode.toggle"]
        let playNow = app.buttons["player.upNext.play"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "offered when episode 1 ends")
        // Tick first: the card counts down while the checks run.
        XCTAssertEqual(toggle.value as? String, "0", "nothing is deleted unless ticked")
        toggle.tap()
        XCTAssertTrue(playNow.waitForExistence(timeout: 5), "Next Episode is on the same card")
        XCTAssertTrue(app.staticTexts["Fixture Show Ep. 2"].exists)
        wait(for: toggle, "value == '1'", timeout: 3, "ticked")
        playNow.tap()
        wait(for: playNow, "exists == false", timeout: 10, "Next Episode starts episode 2")

        // Episode 2, the last, ends: Done instead of Next Episode, and left unticked it's kept.
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "offered when episode 2 ends")
        XCTAssertTrue(app.buttons["player.endCard.done"].exists)
        XCTAssertFalse(playNow.exists, "nothing follows the last episode")
        closePlayer()
        let episodes = app.buttons.matching(identifier: "show.episode")
        wait(for: episodes.element(boundBy: 1), "exists == false", timeout: 5, "episode 1 was deleted")
        XCTAssertTrue(episodes.element(boundBy: 0).label.contains("Ep. 2"), episodes.element(boundBy: 0).label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 of 1 watched'")).firstMatch.waitForExistence(timeout: 5))
    }

    /// Settings sums up the library, deletes watched videos when asked, and keeps the cleanup period.
    func testSettingsSumUpTheLibrary() throws {
        downloadBasicAndCaptioned()
        app.buttons.matching(identifier: "library.moreOptions").element(boundBy: 0).tap()
        app.buttons["Mark as Watched"].tap()

        app.tabBars.buttons["Settings"].tap()
        let videos = app.descendants(matching: .any).matching(identifier: "settings.stat.videos").firstMatch
        let watched = app.descendants(matching: .any).matching(identifier: "settings.stat.watched").firstMatch
        XCTAssertTrue(videos.waitForExistence(timeout: 5))
        XCTAssertTrue(videos.label.contains("Videos, 2, 1 unwatched"), videos.label)
        XCTAssertTrue(watched.label.hasPrefix("Watched, 1,"), watched.label)
        let bar = app.descendants(matching: .any).matching(identifier: "settings.storageBar").firstMatch
        XCTAssertTrue(bar.label.contains("Unwatched") && bar.label.contains("Free on iPhone"), bar.label)

        app.buttons["settings.moreStatistics"].tap()
        let site = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '127.0.0.1,'")).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 5), "the videos are listed under their site")
        XCTAssertTrue(site.label.hasSuffix("2 videos"), site.label)
        app.navigationBars.buttons["Settings"].tap()

        // The cleanup period is a choice of days.
        let period = app.buttons["settings.deleteWatched"]
        for _ in 0..<4 where !(period.exists && period.isHittable) { app.swipeUp() }
        period.tap()
        let threeDays = app.buttons["After 3 Days"]
        XCTAssertTrue(threeDays.waitForExistence(timeout: 5))
        threeDays.tap()
        wait(for: period, "label CONTAINS 'After 3 Days' OR value CONTAINS 'After 3 Days'", timeout: 5, period.debugDescription)

        let deleteWatched = app.buttons["settings.deleteAllWatched"]
        XCTAssertTrue(deleteWatched.label.hasPrefix("Delete All Watched Videos (1,"), deleteWatched.label)
        deleteWatched.tap()
        app.alerts.buttons["Delete"].tap()
        wait(for: deleteWatched, "isEnabled == false", timeout: 5, "nothing watched is left")
        for _ in 0..<4 where !videos.exists { app.swipeDown() }
        wait(for: videos, "label CONTAINS 'Videos, 1, 1 unwatched'", timeout: 5, videos.label)

        app.tabBars.buttons["My Videos"].tap()
        XCTAssertEqual(libraryTitles, ["Basic Video Page"], "the watched video was deleted")
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

        // Watched past 10 s: the video is offered at the top of My Videos and resumes where it stopped.
        XCTAssertTrue(app.buttons["library.hero.play"].waitForExistence(timeout: 5))
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
