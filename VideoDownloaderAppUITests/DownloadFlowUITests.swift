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

        app.tabBars.buttons["Library"].tap()
        let libraryItem = app.buttons["library.item"].firstMatch
        XCTAssertTrue(libraryItem.waitForExistence(timeout: 5))
        XCTAssertTrue(libraryItem.label.contains("Basic Video Page"), libraryItem.label)

        // Playback
        libraryItem.tap()
        XCTAssertTrue(app.otherElements["player.video"].waitForExistence(timeout: 5) || app.otherElements["Video"].waitForExistence(timeout: 2))
        let export = app.buttons["player.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10) || app.sheets.firstMatch.waitForExistence(timeout: 2),
                      "share sheet should appear")
        // iOS 18 presents a sheet (swipe down); iOS 26 a popover (tap outside).
        let shareSheet = app.otherElements["ActivityListView"]
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown(velocity: .fast) }
        if shareSheet.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: libraryItem)], timeout: 5), .completed)

        // Rename
        libraryItem.press(forDuration: 1.2)
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
        XCTAssertTrue(app.buttons["Add This Page"].waitForExistence(timeout: 5))
        app.buttons["Add This Page"].tap()

        let address = app.textFields["browser.address"]
        app.buttons["Clear address"].tap()
        address.tap()
        address.typeText(server.url("/page/iframe.html").absoluteString + "\n")
        let button = waitForReadyCandidates(1)
        button.tap()
        XCTAssertTrue(app.buttons["candidate.download"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "candidate.download").count, 1, "navigating clears the previous page's candidates")
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
}
