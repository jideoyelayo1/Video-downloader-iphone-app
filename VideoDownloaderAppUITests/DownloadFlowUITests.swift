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

        app.tabBars.buttons["My Videos"].tap()
        let libraryItem = app.buttons["library.item"].firstMatch
        XCTAssertTrue(libraryItem.waitForExistence(timeout: 5))
        XCTAssertTrue(libraryItem.label.contains("Basic Video Page"), libraryItem.label)
        XCTAssertTrue(libraryItem.label.contains("Downloaded"), libraryItem.label)

        // Playback
        libraryItem.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 5) || app.otherElements["Video"].waitForExistence(timeout: 2))
        let done = app.buttons["player.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
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
