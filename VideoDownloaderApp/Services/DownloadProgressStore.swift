import Foundation

/// Live download progress, kept apart from `DownloadManager` so a progress tick only
/// re-renders the views that show it, not every tab that uses the manager.
@MainActor
final class DownloadProgressStore: ObservableObject {
    /// Throttled values for display.
    @Published private(set) var fractions: [UUID: Double] = [:]
    @Published private(set) var estimatedSeconds: [UUID: TimeInterval] = [:]
    /// Unthrottled values, so callers that read rather than observe never see a stale fraction.
    private var latest: [UUID: Double] = [:]
    private var lastPublished: [UUID: Date] = [:]

    func fraction(of id: UUID) -> Double? { latest[id] }

    func set(_ id: UUID, fraction: Double, now: Date = Date()) {
        latest[id] = fraction
        let elapsed = now.timeIntervalSince(lastPublished[id] ?? .distantPast)
        guard ProgressThrottle.shouldPublish(previous: fractions[id], current: fraction, secondsSincePublish: elapsed) else { return }
        fractions[id] = fraction
        lastPublished[id] = now
    }

    func setEstimate(_ id: UUID, _ seconds: TimeInterval?) {
        if estimatedSeconds[id] != seconds { estimatedSeconds[id] = seconds }
    }

    func remove(_ id: UUID) {
        latest[id] = nil
        lastPublished[id] = nil
        // Assigning nil to a missing key would still notify observers.
        if fractions[id] != nil { fractions[id] = nil }
        if estimatedSeconds[id] != nil { estimatedSeconds[id] = nil }
    }
}

enum ProgressThrottle {
    static let interval: TimeInterval = 0.25

    /// Direct downloads report every few kilobytes. Publish a few times a second,
    /// but always show the first value, a finished transfer, and a restart.
    static func shouldPublish(previous: Double?, current: Double, secondsSincePublish: TimeInterval) -> Bool {
        guard let previous else { return true }
        if current == previous { return false }
        if current >= 1 || current < previous { return true }
        return secondsSincePublish >= interval
    }
}
