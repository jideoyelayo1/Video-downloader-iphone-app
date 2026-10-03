import SwiftData
import UIKit
import WebKit

/// Downloads the episodes after the one open in Browse, and checks whether a followed show's
/// next episode is out. Each episode page opens in a hidden browser that starts its player
/// muted, so the same discovery and checks as Browse find its video. Pages behind a site's
/// verification (Cloudflare) aren't bypassed: the run stops there.
@MainActor
final class SeasonDownloader: ObservableObject {
    /// "Finding episode 3 of 12…", or why the last run stopped.
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false

    private let downloads: DownloadManager
    private let shows: ShowStore
    var diagnostics: DiagnosticsLog?
    /// How long a page may take to offer a ready video.
    var pageTimeout: TimeInterval = 30
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

    /// Downloads up to `count` episodes after `page`, one page at a time.
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
            // Already in the library (or downloading): nothing to fetch for this one.
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

    /// Downloads a found page's video under the page's title, with its subtitles and poster.
    @discardableResult
    func download(_ result: PageResult) -> DownloadItem? {
        guard case .found(var candidate, let probe, let subtitles, let title, let poster) = result else { return nil }
        candidate.kind = probe.kind
        if !title.isEmpty { candidate.title = title }
        return downloads.start(candidate, expectedBytes: probe.expectedBytes, preferredBitrate: nil,
                               requiresReferer: probe.requiresReferer, subtitles: subtitles, poster: poster)
    }

    private static func episodes(_ count: Int) -> String { count == 1 ? "1 episode" : "\(count) episodes" }

    private func finish(_ message: String) {
        status = message
        isRunning = false
        diagnostics?.record(event: "season", url: "app://season", note: message)
    }

    // MARK: Finding a page's video

    /// Opens the page in the hidden browser and waits for its best ready video.
    func findVideo(on page: URL) async -> PageResult {
        let model = BrowserViewModel(initialURL: page, diagnostics: diagnostics, history: nil, autoplay: true)
        let webView = model.makeWebView()
        // Each search has its own window, so a season run and a new-episode check can't remove
        // each other's, and nothing stays on screen afterwards.
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
            if model.bestReady != nil {
                readySince = readySince ?? Date()
                // Give the page a moment to offer a master playlist beside its first stream.
                if !model.isChecking || Date().timeIntervalSince(readySince!) > 4 { break }
            }
        }
        guard let best = model.bestReady else { return .noVideo }
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
