import Foundation

/// Builds signed with a free developer account stop opening when their provisioning profile
/// expires, seven days after Xcode issued it; iOS then says the app "is no longer available".
/// A copy that is already running (often kept alive by Picture in Picture) carries on until it
/// is closed. The date comes from the profile embedded in the app; App Store and TestFlight
/// builds, and simulator builds, have none.
enum BuildExpiry {
    static let date: Date? = {
        #if DEBUG
        // Lets screenshots and UI tests show the warning on the simulator.
        if let hours = LaunchOptions.value("-BuildExpiresInHours").flatMap(Double.init) { return Date().addingTimeInterval(hours * 3600) }
        #endif
        return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap(expiry(inProfile:))
    }()

    /// The profile is a signed (CMS) container around an XML property list.
    static func expiry(inProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return object?["ExpirationDate"] as? Date
    }

    /// A warning once less than two days remain.
    static func warning(expiry: Date?, now: Date = Date()) -> String? {
        guard let expiry, expiry.timeIntervalSince(now) < 48 * 3600 else { return nil }
        guard expiry > now else {
            return "This copy of Video Downloader has expired and won't open again once it's closed. Reinstall it from Xcode. Your videos are kept."
        }
        let when = expiry.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "This copy of Video Downloader stops opening on \(when). Reinstall it from Xcode before then. Your videos are kept."
    }
}
