import SwiftData
import UIKit
import WebKit

/// Finds episodes in a hidden, muted-autoplay browser; pages behind Cloudflare verification stop the run.
@MainActor
final class SeasonDownloader: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false

    private let downloads: DownloadManager
    private let shows: ShowStore
    var diagnostics: DiagnosticsLog?
    var pageTimeout: TimeInterval = 30
    /// Smaller videos are a player's ads, not the episode (My***REMOVED*** showed 0.3 and 1.4 MB ones).
    var minimumEpisodeBytes: Int64 = 5_000_000
    private var task: Task<Void, Never>?

    init(downloads: DownloadManager, shows: ShowStore) {
        self.downloads = downloads
        self.shows = shows
    }

    enum PageResult: Equatable {
        case found(MediaCandidate, ProbeResult, [SubtitleTrack], title: String, poster: URL? = nil)
        case noVideo
        case verification
        case unsupported

        static func == (lhs: PageResult, rhs: PageResult) -> Bool {
            switch (lhs, rhs) {
            case (.noVideo, .noVideo), (.verification, .verification), (.unsupported, .unsupported): return true
            case (.found(let a, _, _, _, _), .found(let b, _, _, _, _)): return a.url == b.url
            default: return false
            }
        }
    }

    func start(after page: URL, count: Int) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.run(after: page, count: count)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        finish("Stopped.")
    }

    private func run(after page: URL, count: Int) async {
        var current = page
        var queued = 0
        for index in 1...max(count, 1) {
            guard !Task.isCancelled else { return }
            guard let next = EpisodeURL.next(after: current) else {
                finish(queued == 0 ? "This site's episode addresses can't be followed." : "Queued \(Self.episodes(queued)).")
                return
            }
            current = next
            if downloads.savedOrActiveEpisode(atPage: next) != nil { continue }
            status = "Finding episode \(index) of \(count)…"
            let result = await findVideo(on: next)
            guard !Task.isCancelled else { return }
            switch result {
            case .found:
                if download(result) != nil { queued += 1 }
            case .verification:
                finish("Stopped at episode \(index): the site wants you to verify in Browse first. Queued \(queued).")
                return
            case .noVideo, .unsupported:
                finish(queued == 0 ? "No video found for the next episode. It may not be out yet." : "Queued \(Self.episodes(queued)); no video found for the next one.")
                return
            }
        }
        finish("Queued \(Self.episodes(queued)).")
    }

    @discardableResult
    func download(_ result: PageResult) -> DownloadItem? {
        guard case .found(var candidate, let probe, let subtitles, let title, let poster) = result else { return nil }
        candidate.kind = probe.kind
        if !title.isEmpty { candidate.title = title }
        return downloads.start(candidate, expectedBytes: probe.expectedBytes, preferredBitrate: nil,
                               requiresReferer: probe.requiresReferer, subtitles: subtitles, poster: poster)
    }

    /// Re-finds an expired link on its page and restarts the same row; false if the page has no video now.
    func refreshLink(of item: DownloadItem) async -> Bool {
        guard case .found(let found, let probe, let subtitles, _, let poster) = await findVideo(on: item.sourcePageURL) else { return false }
        // The row's page and title, so start() repairs this row instead of adding another.
        let candidate = MediaCandidate(url: found.url, sourcePageURL: item.sourcePageURL, frameURL: found.frameURL ?? found.sourcePageURL,
                                       isMainFrame: found.isMainFrame, title: item.title, kind: probe.kind, contentType: found.contentType)
        return downloads.start(candidate, expectedBytes: probe.expectedBytes, preferredBitrate: item.preferredBitrate,
                               requiresReferer: probe.requiresReferer, subtitles: subtitles, poster: poster) != nil
    }

    private static func episodes(_ count: Int) -> String { count == 1 ? "1 episode" : "\(count) episodes" }

    private func finish(_ message: String) {
        status = message
        isRunning = false
        diagnostics?.record(event: "season", url: "app://season", note: message)
    }

    // MARK: Finding a page's video

    func findVideo(on page: URL) async -> PageResult {
        let model = BrowserViewModel(initialURL: page, diagnostics: diagnostics, history: nil, autoplay: true)
        let webView = model.makeWebView()
        // A window per search, so a season run and a new-episode check can't remove each other's.
        let window = Self.hostingWindow()
        webView.frame = window.bounds
        window.rootViewController?.view.addSubview(webView)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
            window.isHidden = true
        }
        let deadline = Date().addingTimeInterval(pageTimeout)
        var readySince: Date?
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if Self.isVerificationPage(title: model.pageTitle) { return .verification }
            if model.bestReady(atLeast: minimumEpisodeBytes) != nil {
                readySince = readySince ?? Date()
                // Give the page a moment to offer a master playlist beside its first stream.
                if !model.isChecking || Date().timeIntervalSince(readySince!) > 4 { break }
            }
        }
        guard let best = model.bestReady(atLeast: minimumEpisodeBytes) else { return .noVideo }
        // A site can send an episode that isn't out to another one: ***REMOVED*** opens episode 1.
        if let wanted = EpisodeURL.number(in: page), EpisodeURL.number(in: best.candidate.sourcePageURL) != wanted { return .noVideo }
        return .found(best.candidate, best.probe, model.subtitleTracks, title: model.pageTitle, poster: model.posterURL)
    }

    static func isVerificationPage(title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("just a moment") || lower.contains("attention required") || lower.contains("verify you are human")
    }

    /// A web view runs its page and players only while it's in a window, behind the app's own.
    private static func hostingWindow() -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.alpha = 0.01
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }
}
