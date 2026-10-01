import Foundation

/// The viewer's last caption choice, applied to every saved video.
enum CaptionPreference {
    static let defaultsKey = "captionPreference"
    /// No captions at all (AVKit's Off on iOS 18).
    static let off = "off"
    /// Only forced subtitles, for foreign-language lines and signs (AVKit's Off on iOS 26, and
    /// Auto (Recommended) on iOS 18).
    static let forcedOnly = "forced"

    struct Option: Equatable {
        /// BCP 47 tag such as `en` or `en-US`, when the track declares one.
        let language: String?
        let name: String
    }

    /// The track to select, or nil for captions off.
    /// - Parameters:
    ///   - stored: nil if the viewer has never chosen; otherwise `off` or a remembered language or track name.
    ///   - defaultIndex: what to show when there is no usable preference.
    static func index(for stored: String?, in options: [Option], defaultIndex: Int?) -> Int? {
        guard let stored else { return defaultIndex }
        if stored == off || stored == forcedOnly { return nil }
        if let exact = options.firstIndex(where: { $0.language == stored || $0.name == stored }) { return exact }
        // "en" chosen on one video should still match "en-US" on another.
        let base = stored.split(separator: "-").first.map(String.init)?.lowercased()
        if let base, let related = options.firstIndex(where: { $0.language?.split(separator: "-").first.map(String.init)?.lowercased() == base }) {
            return related
        }
        return defaultIndex
    }

    static func storedValue(for option: Option?) -> String {
        guard let option else { return off }
        return option.language ?? option.name
    }
}
