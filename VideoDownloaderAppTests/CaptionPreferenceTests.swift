import XCTest
@testable import VideoDownloaderApp

final class CaptionPreferenceTests: XCTestCase {
    private let options = [
        CaptionPreference.Option(language: "en-US", name: "English"),
        CaptionPreference.Option(language: "es", name: "Español"),
        CaptionPreference.Option(language: nil, name: "Signs & Songs")
    ]

    func testNoChoiceKeepsTheDefaultTrack() {
        XCTAssertEqual(CaptionPreference.index(for: nil, in: options, defaultIndex: 0), 0)
        XCTAssertNil(CaptionPreference.index(for: nil, in: [], defaultIndex: nil))
    }

    func testOffIsRemembered() {
        XCTAssertNil(CaptionPreference.index(for: CaptionPreference.off, in: options, defaultIndex: 0))
        XCTAssertNil(CaptionPreference.index(for: CaptionPreference.forcedOnly, in: options, defaultIndex: 0))
        XCTAssertEqual(CaptionPreference.storedValue(for: nil), CaptionPreference.off)
    }

    func testLanguageMatchesExactlyThenByBaseLanguage() {
        XCTAssertEqual(CaptionPreference.index(for: "es", in: options, defaultIndex: 0), 1)
        XCTAssertEqual(CaptionPreference.index(for: "en", in: options, defaultIndex: 1), 0)
        XCTAssertEqual(CaptionPreference.index(for: "en-GB", in: options, defaultIndex: 1), 0)
    }

    func testNamedTrackWithoutLanguageIsRememberedByName() {
        let stored = CaptionPreference.storedValue(for: options[2])
        XCTAssertEqual(stored, "Signs & Songs")
        XCTAssertEqual(CaptionPreference.index(for: stored, in: options, defaultIndex: 0), 2)
    }

    func testUnavailableLanguageFallsBackToDefault() {
        XCTAssertEqual(CaptionPreference.index(for: "ja", in: options, defaultIndex: 0), 0)
    }
}
