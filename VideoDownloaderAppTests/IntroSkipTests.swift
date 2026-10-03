import XCTest
@testable import VideoDownloaderApp

final class IntroSkipTests: XCTestCase {
    func testSkipIntroShowsOnlyInsideTheMarkedIntro() {
        XCTAssertFalse(IntroSkip.isInIntro(5, start: nil, end: 90))
        XCTAssertFalse(IntroSkip.isInIntro(5, start: 10, end: 90), "before the intro")
        XCTAssertTrue(IntroSkip.isInIntro(10, start: 10, end: 90))
        XCTAssertTrue(IntroSkip.isInIntro(60, start: 10, end: 90))
        XCTAssertFalse(IntroSkip.isInIntro(89.8, start: 10, end: 90), "its last half second is left alone")
        XCTAssertFalse(IntroSkip.isInIntro(60, start: 90, end: 10), "marks the wrong way round")
    }

    func testCreditsAreMeasuredFromTheEnd() {
        XCTAssertEqual(IntroSkip.creditsStart(duration: 1_440, fromEnd: 90), 1_350)
        XCTAssertEqual(IntroSkip.creditsStart(duration: 1_400, fromEnd: 90), 1_310, "episodes of another length")
        XCTAssertNil(IntroSkip.creditsStart(duration: nil, fromEnd: 90))
        XCTAssertNil(IntroSkip.creditsStart(duration: 60, fromEnd: 90))
        XCTAssertEqual(IntroSkip.timeText(90), "1:30")
        XCTAssertEqual(IntroSkip.timeText(3_725), "1:02:05")
    }
}
