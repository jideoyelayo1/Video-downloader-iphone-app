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
}
