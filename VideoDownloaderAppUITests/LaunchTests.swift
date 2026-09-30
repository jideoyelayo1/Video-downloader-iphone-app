import XCTest

final class LaunchTests: XCTestCase {
    func testLaunchShowsThreeTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-NoInitialLoad", "-UITestInMemory"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Browse"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Downloads"].exists)
        XCTAssertTrue(app.tabBars.buttons["My Videos"].exists)
    }
}
