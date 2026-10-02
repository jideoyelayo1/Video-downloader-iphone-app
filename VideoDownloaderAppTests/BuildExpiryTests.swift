import XCTest
@testable import VideoDownloaderApp

final class BuildExpiryTests: XCTestCase {
    func testExpiryIsReadFromTheSignedProfile() throws {
        let expiry = Date(timeIntervalSince1970: 1_790_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "iOS Team Provisioning Profile", "ExpirationDate": expiry],
                                                       format: .xml, options: 0)
        // The XML sits inside binary CMS signing data.
        let profile = Data([0x30, 0x80, 0x06, 0x09, 0x2A]) + plist + Data([0xA0, 0x82, 0x0B, 0x00])
        XCTAssertEqual(BuildExpiry.expiry(inProfile: profile), expiry)
        XCTAssertNil(BuildExpiry.expiry(inProfile: Data("not a profile".utf8)))
    }

    func testWarningAppearsInTheLastTwoDays() throws {
        let now = Date()
        XCTAssertNil(BuildExpiry.warning(expiry: nil, now: now), "App Store and simulator builds have no profile")
        XCTAssertNil(BuildExpiry.warning(expiry: now.addingTimeInterval(3 * 86_400), now: now))
        let soon = try XCTUnwrap(BuildExpiry.warning(expiry: now.addingTimeInterval(20 * 3600), now: now))
        XCTAssertTrue(soon.contains("stops opening on") && soon.contains("Reinstall it from Xcode"), soon)
        let expired = try XCTUnwrap(BuildExpiry.warning(expiry: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(expired.contains("has expired"), expired)
    }
}
