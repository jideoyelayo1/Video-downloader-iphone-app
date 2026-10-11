import XCTest

final class LaunchTests: XCTestCase {
    func testLaunchShowsFourTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-NoInitialLoad", "-UITestInMemory"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Browse"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Downloads"].exists)
        XCTAssertTrue(app.tabBars.buttons["My Videos"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        XCTAssertFalse(app.staticTexts["library.expiryWarning"].exists, "simulator builds have no expiry")
    }

    /// Free developer builds stop opening seven days after they were signed; My Videos warns first.
    func testExpiryWarningShowsAndCanBeDismissed() {
        let app = XCUIApplication()
        app.launchArguments = ["-NoInitialLoad", "-UITestInMemory", "-BuildExpiresInHours", "20"]
        app.launch()
        let warning = app.staticTexts["library.expiryWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(warning.label.contains("Reinstall it from Xcode"), warning.label)
        app.buttons["Dismiss"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: warning)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed)
    }
}
