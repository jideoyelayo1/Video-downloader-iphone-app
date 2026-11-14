import Foundation

enum IntroSkip {
    /// Inside the marked intro, leaving its last half second alone so a skip doesn't land just short of it.
    static func isInIntro(_ position: Double, start: Double?, end: Double?) -> Bool {
        guard let start, let end, end > start, position.isFinite else { return false }
        return position >= start && position < end - 0.5
    }

    /// Credits are marked as a distance from the end.
    static func creditsStart(duration: Double?, fromEnd: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0, let fromEnd, fromEnd > 0, fromEnd < duration else { return nil }
        return duration - fromEnd
    }

    static func timeText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
