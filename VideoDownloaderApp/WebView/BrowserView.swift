import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var model: BrowserViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Keep a site's player controls and external caption overlays with its
        // video. Forcing native full screen hides JW Player subtitle layers.
        configuration.allowsInlineMediaPlayback = true
        if LaunchOptions.autoplay { configuration.mediaTypesRequiringUserActionForPlayback = [] }
        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(model.discovery), name: MediaDiscovery.messageName)
        model.discovery.userScripts(diagnosticsEnabled: LaunchOptions.diagnosticsEnabled, autoplay: LaunchOptions.autoplay)
            .forEach(contentController.addUserScript)
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "browser.webView"
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        model.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserViewModel
        init(model: BrowserViewModel) { self.model = model }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            model.pageDidChange(to: webView.url, force: true)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { model.syncState() }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
            model.didFinishPage()
            if BrowserSession.userAgent == nil {
                webView.evaluateJavaScript("navigator.userAgent") { value, _ in
                    Task { @MainActor in BrowserSession.userAgent = value as? String }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { model.loadFailed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { model.loadFailed(error) }

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
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageTitle = ""

    let discovery = MediaDiscoveryController()
    let diagnostics: DiagnosticsLog?
    private let history: BrowserHistoryStore?
    private weak var webView: WKWebView?
    private var pendingURL: URL?
    private let validator: CandidateValidator
    private let contextProvider: DownloadManager.ContextProvider
    /// Variant playlists already represented by a master playlist in the list.
    private var variantURLs: Set<URL> = []
    /// Incremented on every page change so late probe results for the old page are dropped.
    private var generation = 0

    init(initialURL: URL? = LaunchOptions.initialURL, diagnostics: DiagnosticsLog? = nil, history: BrowserHistoryStore? = nil,
         validator: CandidateValidator = CandidateValidator(),
         contextProvider: @escaping DownloadManager.ContextProvider = { url, referer in await BrowserSession.requestContext(for: url, referer: referer) }) {
        self.diagnostics = diagnostics
        self.history = history
        self.validator = validator
        self.contextProvider = contextProvider
        pendingURL = initialURL
        addressText = initialURL?.absoluteString ?? ""
        discovery.diagnostics = diagnostics
        discovery.onCandidate = { [weak self] candidate in self?.add(candidate) }
        discovery.onNavigation = { [weak self] newURL in self?.pageDidChange(to: newURL, force: false) }
        discovery.onFragment = { [weak self] in self?.observedFragments = true }
    }

    var readyCount: Int { statuses.values.filter(\.isReady).count }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        discovery.webView = webView
        if let pendingURL {
            self.pendingURL = nil
            webView.load(URLRequest(url: pendingURL))
        }
    }

    func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let target = URL(string: value), ["http", "https"].contains(target.scheme?.lowercased()), target.host != nil else {
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

    func syncState() {
        guard let webView else { return }
        if let current = webView.url { url = current; addressText = current.absoluteString }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? ""
    }

    func didFinishPage() {
        syncState()
        if let url { history?.record(url, title: pageTitle) }
    }

    func loadFailed(_ error: Error) {
        isLoading = false
        let nsError = error as NSError
        // Cancelled loads (-999) and interrupted frame loads (102) are normal during redirects and downloads.
        if (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        errorMessage = error.localizedDescription
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
        if let newURL, ["http", "https"].contains(newURL.scheme?.lowercased()) {
            url = newURL
            addressText = newURL.absoluteString
            if !force { history?.record(newURL, title: newURL.host ?? "") }
        }
    }

    func add(_ candidate: MediaCandidate) {
        guard !variantURLs.contains(MediaDiscovery.normalizedURL(candidate.url)),
              !MediaDiscovery.isDuplicate(candidate, in: candidates) else { return }
        candidates.insert(candidate, at: 0)
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
            if !probe.variants.isEmpty {
                let variants = Set(probe.variants.map { MediaDiscovery.normalizedURL($0.url) })
                variantURLs.formUnion(variants)
                let hidden = candidates.filter { $0.id != candidate.id && variants.contains(MediaDiscovery.normalizedURL($0.url)) }
                candidates.removeAll { hidden.map(\.id).contains($0.id) }
                hidden.forEach { statuses[$0.id] = nil }
            }
            diagnostics?.record(event: "probe", url: candidate.url.absoluteString,
                                note: "ready \(probe.kind.rawValue), \(probe.variants.count) variants, bytes=\(probe.expectedBytes.map(String.init) ?? "?")")
        case .unavailable(let error):
            diagnostics?.record(event: "probe", url: candidate.url.absoluteString, note: "unavailable: \(error.message)")
        case .checking:
            break
        }
    }
}
