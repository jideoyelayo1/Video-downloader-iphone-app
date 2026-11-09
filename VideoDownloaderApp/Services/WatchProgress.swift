import Foundation

/// When a video counts as watched: it played to the end, or it was closed in its last 10%,
/// which is usually the end credits.
enum WatchProgress {
    static let finishedFraction = 0.9

    static func isFinished(position: Double, duration: Double?) -> Bool {
        guard let duration, duration.isFinite, duration > 0, position.isFinite else { return false }
        return position >= duration * finishedFraction
    }
}

extension DownloadItem {
    /// Marking a video watched also clears its resume point, so it leaves Continue Watching.
    func setWatched(_ watched: Bool, at date: Date = Date()) {
        watchedAt = watched ? date : nil
        if watched { playbackPosition = 0 }
    }

    /// Where playback got to, on the phone or a Chromecast; closing in the last 10% marks it watched instead.
    /// - Returns: whether closing counted as finishing the video.
    @discardableResult
    func recordPosition(_ seconds: Double, duration: Double?, closing: Bool) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        let finished = closing && WatchProgress.isFinished(position: seconds, duration: duration)
        if finished { setWatched(true) } else { playbackPosition = seconds }
        return finished
    }
}
