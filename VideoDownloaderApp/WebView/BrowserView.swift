import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        // The model owns the web view, so a SwiftUI re-creation reattaches the same
        // page instead of starting a second, blank WebKit process.
        let webView = model.makeWebView()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserViewModel
        init(model: BrowserViewModel) { self.model = model }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.pageDidChange(to: webView.url, force: true)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { model.syncState() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.didFinishPage()
            if BrowserSession.userAgent == nil {
                webView.evaluateJavaScript("navigator.userAgent") { value, _ in
                    Task { @MainActor in BrowserSession.userAgent = value as? String }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { model.loadFailed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { model.loadFailed(error) }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { model.webContentProcessDidTerminate() }

        /// Opens `target="_blank"` links the user tapped in the same view; script-opened popups (usually ads) are dropped.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
            return nil
        }
    }
}

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published var addressText = ""
    @Published private(set) var candidates: [MediaCandidate] = []
    @Published private(set) var observedFragments = false
    @Published private(set) var statuses: [UUID: CandidateStatus] = [:]
    /// Subtitle files the page's players offer; saved with a download from this page.
    @Published private(set) var subtitleTracks: [SubtitleTrack] = []
    /// Artwork for downloads from this page: a player's poster, else the page's preview image.
    @Published private(set) var posterURL: URL?
    private var posterIsFromPlayer = false
    @Published private(set) var isLoading = false
    /// Page load progress, published in coarse steps for the address bar's loading line.
    @Published private(set) var loadProgress = 0.0
    @Published var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageTitle = ""
    /// While the user types an address, page URL updates must not replace their text.
    var isEditingAddress = false

    let discovery = MediaDiscoveryController()
    let diagnostics: DiagnosticsLog?
    private let history: BrowserHistoryStore?
    private(set) var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var pendingURL: URL?
    private var lastAutomaticReload: Date?
    /// Whether the page is on screen: the Browse tab, in the foreground, with no saved video over it.
    var isVisible = true {
        didSet { if isVisible && !oldValue && pendingCrashReload { reloadAfterCrash(now: Date()) } }
    }
    /// A page that crashed while hidden, often during Picture in Picture, reloads when it is shown
    /// again instead of loading, and streaming, in the background.
    private(set) var pendingCrashReload = false
    private let validator: CandidateValidator
    private let contextProvider: DownloadManager.ContextProvider
    /// Variant and rendition playlists already represented by a master playlist in the list.
    private var variantURLs: Set<URL> = []
    /// Incremented on every page change so late probe results for the old page are dropped.
    private var generation = 0
    /// Starts players muted so they reveal their streams; for the hidden browser that finds episodes.
    private let autoplay: Bool

    init(initialURL: URL? = LaunchOptions.initialURL, diagnostics: DiagnosticsLog? = nil, history: BrowserHistoryStore? = nil,
         autoplay: Bool = LaunchOptions.autoplay, validator: CandidateValidator = CandidateValidator(),
         contextProvider: @escaping DownloadManager.ContextProvider = { url, referer in await BrowserSession.requestContext(for: url, referer: referer) }) {
        self.diagnostics = diagnostics
        self.history = history
        self.autoplay = autoplay
        self.validator = validator
        self.contextProvider = contextProvider
        pendingURL = initialURL
        addressText = initialURL?.absoluteString ?? ""
        discovery.diagnostics = diagnostics
        discovery.onCandidate = { [weak self] candidate in self?.add(candidate) }
        discovery.onNavigation = { [weak self] newURL in self?.pageDidChange(to: newURL, force: false) }
        discovery.onFragment = { [weak self] in self?.observedFragments = true }
        discovery.onSubtitles = { [weak self] tracks in self?.addSubtitles(tracks) }
        discovery.onPoster = { [weak self] url, fromPlayer in
            guard let self, self.posterURL == nil || (fromPlayer && !self.posterIsFromPlayer) else { return }
            self.posterURL = url
            self.posterIsFromPlayer = fromPlayer
        }
    }

    var readyCount: Int { statuses.values.filter(\.isReady).count }

    var isChecking: Bool { candidates.contains { statuses[$0.id] == nil || statuses[$0.id] == .checking } }

    /// The video Found videos lists first: a master playlist, else the longest, then largest.
    /// Videos known to be smaller than `minimumBytes` are left out.
    func bestReady(atLeast minimumBytes: Int64) -> (candidate: MediaCandidate, probe: ProbeResult)? {
        let ready = candidates.compactMap { candidate -> (MediaCandidate, ProbeResult)? in
            if case .ready(let probe)? = statuses[candidate.id], (probe.expectedBytes ?? .max) >= minimumBytes { return (candidate, probe) }
            return nil
        }
        return ready.max { a, b in
            let rank = { (probe: ProbeResult) in (probe.kind == .hls && !probe.variants.isEmpty ? 1 : 0, probe.duration ?? 0, Double(probe.expectedBytes ?? 0)) }
            return rank(a.1) < rank(b.1)
        }
    }

    /// Returns the browser's single web view, creating and loading it on first use.
    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        // Keep a site's player controls and external caption overlays with its
        // video. Forcing native full screen hides JW Player subtitle layers.
        configuration.allowsInlineMediaPlayback = true
        if autoplay { configuration.mediaTypesRequiringUserActionForPlayback = [] }
        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(discovery), name: MediaDiscovery.messageName)
        discovery.userScripts(diagnosticsEnabled: LaunchOptions.diagnosticsEnabled, autoplay: autoplay)
            .forEach(contentController.addUserScript)
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "browser.webView"
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        attach(webView)
        return webView
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        discovery.webView = webView
        observe(webView)
        if let pendingURL {
            self.pendingURL = nil
            webView.load(URLRequest(url: pendingURL))
        }
    }

    /// Navigation callbacks miss same-document changes (pushState) that some routers make
    /// without going through the page's `history.pushState`, so the web view's own state is watched.
    private func observe(_ webView: WKWebView) {
        func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ update: @escaping @MainActor @Sendable (BrowserViewModel, WKWebView) -> Void) -> NSKeyValueObservation {
            webView.observe(keyPath, options: [.new]) { [weak self] webView, _ in
                let apply = {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        update(self, webView)
                    }
                }
                // WebKit reports these on the main thread; never assume isolation anywhere else.
                if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
            }
        }
        observations = [
            watch(\.url) { model, webView in model.webViewURLChanged(webView) },
            watch(\.title) { model, webView in model.webViewTitleChanged(webView) },
            watch(\.canGoBack) { model, webView in model.canGoBack = webView.canGoBack },
            watch(\.canGoForward) { model, webView in model.canGoForward = webView.canGoForward },
            watch(\.isLoading) { model, webView in
                model.isLoading = webView.isLoading
                if !webView.isLoading { model.loadProgress = 0 }
            },
            watch(\.estimatedProgress) { model, webView in
                let value = webView.estimatedProgress
                // Progress arrives in many tiny steps; the loading line only needs a few.
                if value >= 1 || value < model.loadProgress || value - model.loadProgress >= 0.05 { model.loadProgress = value }
            }
        ]
    }

    private func webViewURLChanged(_ webView: WKWebView) {
        guard let newURL = webView.url, newURL.isWeb else { return }
        // A full navigation is handled by the navigation delegate once it commits or finishes.
        guard !webView.isLoading else { return }
        pageDidChange(to: newURL, force: false)
        if url != newURL {
            url = newURL
            if !isEditingAddress { addressText = newURL.absoluteString }
        }
    }

    private func webViewTitleChanged(_ webView: WKWebView) {
        pageTitle = webView.title ?? ""
        guard !webView.isLoading, let url, !pageTitle.isEmpty else { return }
        history?.updateTitle(for: url, title: pageTitle)
    }

    func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let target = URL(string: value), target.isWeb, target.host != nil else {
            errorMessage = "Enter a valid web address."
            return
        }
        addressText = target.absoluteString
        if let webView { webView.load(URLRequest(url: target)) } else { pendingURL = target }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func rescan() { discovery.rescan() }

    /// Stops the page's audio and video, e.g. when the user leaves Browse or plays a saved video.
    func pauseMedia() {
        // The Objective-C completion-handler form; Swift-refined WebKit overlays crash at launch on iOS 18.
        webView?.pauseAllMediaPlayback(completionHandler: nil)
    }

    func syncState() {
        guard let webView else { return }
        if let current = webView.url {
            url = current
            if !isEditingAddress { addressText = current.absoluteString }
        }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? ""
    }

    func didFinishPage() {
        syncState()
        if let url { history?.record(url, title: pageTitle) }
    }

    func loadFailed(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads (-999) and interrupted frame loads (102) are normal during redirects and downloads.
        if (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        errorMessage = error.localizedDescription
    }

    /// WebKit ends a page's content process when it uses too much memory, leaving a blank view.
    /// Reload once automatically; a page that keeps crashing waits for the user.
    func webContentProcessDidTerminate(now: Date = Date()) {
        diagnostics?.record(event: "webcontent-terminated", url: url?.absoluteString ?? "about:blank",
                            note: isVisible ? nil : "Reloads when Browse is shown")
        pageDidChange(to: url, force: true)
        guard isVisible else {
            pendingCrashReload = true
            return
        }
        reloadAfterCrash(now: now)
    }

    private func reloadAfterCrash(now: Date) {
        pendingCrashReload = false
        if let last = lastAutomaticReload, now.timeIntervalSince(last) < 30 {
            errorMessage = "This page stopped because it used too much memory. Tap Reload to try again."
            return
        }
        lastAutomaticReload = now
        guard let webView else { return }
        if webView.url != nil { webView.reload() } else if let url { webView.load(URLRequest(url: url)) }
    }

    /// Clears candidates when the top-level page changes. Same-document history updates only count
    /// when the path or query changed, because players often call replaceState for trivial reasons.
    func pageDidChange(to newURL: URL?, force: Bool) {
        if !force, let newURL, let url, MediaDiscovery.normalizedURL(newURL) == MediaDiscovery.normalizedURL(url) { return }
        generation += 1
        candidates.removeAll()
        observedFragments = false
        statuses.removeAll()
        variantURLs.removeAll()
        subtitleTracks.removeAll()
        posterURL = nil
        posterIsFromPlayer = false
        if let newURL, newURL.isWeb {
            url = newURL
            if !isEditingAddress { addressText = newURL.absoluteString }
            if !force { history?.record(newURL, title: newURL.host ?? "") }
        }
    }

    func addSubtitles(_ tracks: [SubtitleTrack]) {
        let known = Set(subtitleTracks.map(\.url))
        let new = tracks.filter { !known.contains($0.url) }
        if !new.isEmpty { subtitleTracks.append(contentsOf: new) }
    }

    func add(_ candidate: MediaCandidate) {
        guard !variantURLs.contains(MediaDiscovery.normalizedURL(candidate.url)) else { return }
        if let known = candidates.first(where: { MediaDiscovery.isDuplicate(candidate, in: [$0]) }) {
            // A check that timed out or lost the network is tried again when the page offers the video again.
            if case .unavailable(let error) = statuses[known.id], error.isTransient { validate(known) }
            return
        }
        candidates.insert(candidate, at: 0)
        validate(candidate)
    }

    private func validate(_ candidate: MediaCandidate) {
        statuses[candidate.id] = .checking
        let generation = generation
        Task {
            let context = await contextProvider(candidate.url, candidate.referer)
            let status = await validator.validate(candidate, context: context)
            guard generation == self.generation, candidates.contains(where: { $0.id == candidate.id }) else { return }
            apply(status, to: candidate)
        }
    }

    private func apply(_ status: CandidateStatus, to candidate: MediaCandidate) {
        statuses[candidate.id] = status
        switch status {
        case .ready(let probe):
            if let index = candidates.firstIndex(where: { $0.id == candidate.id }) { candidates[index].kind = probe.kind }
            // A master stands in for its variants and its separate audio and subtitle
            // playlists, which would otherwise be offered as (silent or audio-only) videos.
            let covered = Set((probe.variants.map(\.url) + probe.renditions).map(MediaDiscovery.normalizedURL))
            if !covered.isEmpty {
                variantURLs.formUnion(covered)
                let hidden = candidates.filter { $0.id != candidate.id && covered.contains(MediaDiscovery.normalizedURL($0.url)) }
                candidates.removeAll { hidden.map(\.id).contains($0.id) }
                hidden.forEach { statuses[$0.id] = nil }
            }
            diagnostics?.record(event: "probe", url: candidate.url.absoluteString,
                                note: "ready \(probe.kind.rawValue), \(probe.variants.count) variants, \(probe.renditions.count) renditions, bytes=\(probe.expectedBytes.map(String.init) ?? "?")")
        case .unavailable(let error):
            diagnostics?.record(event: "probe", url: candidate.url.absoluteString, note: "unavailable: \(error.message)")
        case .checking:
            break
        }
    }
}
