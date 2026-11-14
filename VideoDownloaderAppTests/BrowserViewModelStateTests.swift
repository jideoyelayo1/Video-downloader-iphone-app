import WebKit
import XCTest
@testable import VideoDownloaderApp

@MainActor
final class BrowserViewModelStateTests: XCTestCase {
    private func makeModel() -> BrowserViewModel {
        BrowserViewModel(initialURL: nil, validator: CandidateValidator(), contextProvider: { _, _ in nil })
    }

    func testPageUpdatesDoNotOverwriteAnAddressBeingTyped() {
        let model = makeModel()
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=1"), force: true)
        model.isEditingAddress = true
        model.addressText = "exam"
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=2"), force: false)
        XCTAssertEqual(model.addressText, "exam")
        XCTAssertEqual(model.url?.absoluteString, "https://site.example/watch?ep=2")
        model.isEditingAddress = false
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=3"), force: false)
        XCTAssertEqual(model.addressText, "https://site.example/watch?ep=3")
    }

    func testSubtitleTracksAreCollectedPerPage() {
        let model = makeModel()
        let page = URL(string: "https://www.***REMOVED***.to/watch/abc/frieren?ep=1")!
        model.pageDidChange(to: page, force: true)
        let english = SubtitleTrack(url: URL(string: "https://s1.example/en/sub.vtt")!, label: "English", language: "en", isDefault: true, referer: nil)
        let arabic = SubtitleTrack(url: URL(string: "https://s1.example/ar/sub.vtt")!, label: "Arabic", language: "ar", isDefault: false, referer: nil)
        model.discovery.onSubtitles?([english])
        model.discovery.onSubtitles?([english, arabic])
        XCTAssertEqual(model.subtitleTracks.map(\.label), ["English", "Arabic"])
        model.pageDidChange(to: URL(string: "https://www.***REMOVED***.to/watch/abc/frieren?ep=2"), force: false)
        XCTAssertTrue(model.subtitleTracks.isEmpty, "the next episode's tracks replace the previous ones")
    }

    func testRepeatedContentProcessCrashesStopAutomaticReloads() {
        let model = makeModel()
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=1"), force: true)
        model.add(MediaCandidate(url: URL(string: "http://127.0.0.1:9/a.mp4")!, sourcePageURL: URL(string: "https://site.example/watch?ep=1")!))
        let start = Date()
        model.webContentProcessDidTerminate(now: start)
        XCTAssertNil(model.errorMessage, "the first crash reloads silently")
        XCTAssertTrue(model.candidates.isEmpty)
        model.webContentProcessDidTerminate(now: start.addingTimeInterval(5))
        XCTAssertNotNil(model.errorMessage, "a page that keeps crashing waits for the user")
        model.errorMessage = nil
        model.webContentProcessDidTerminate(now: start.addingTimeInterval(120))
        XCTAssertNil(model.errorMessage)
    }

    /// WebKit ends hidden pages' processes in long PiP sessions; reloading them unseen wastes memory and data.
    func testAPageThatCrashesWhileHiddenReloadsWhenShown() {
        let model = makeModel()
        model.pageDidChange(to: URL(string: "https://site.example/watch?ep=1"), force: true)
        model.add(MediaCandidate(url: URL(string: "http://127.0.0.1:9/a.mp4")!, sourcePageURL: URL(string: "https://site.example/watch?ep=1")!))
        model.isVisible = false
        model.webContentProcessDidTerminate()
        model.webContentProcessDidTerminate()
        XCTAssertTrue(model.pendingCrashReload)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.errorMessage, "crashes while hidden don't count as a crash loop")
        model.isVisible = true
        XCTAssertFalse(model.pendingCrashReload)
        XCTAssertNil(model.errorMessage)
    }

    /// Routers such as SvelteKit's change the URL without calling the `history.pushState` the script hooks.
    func testSamePageNavigationThatBypassesTheScriptHookIsObserved() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let model = makeModel()
        let webView = model.makeWebView()
        XCTAssertTrue(model.makeWebView() === webView, "the model keeps a single web view")
        // Full page loads are reported by the navigation delegate, as in BrowserView.
        let coordinator = BrowserView.Coordinator(model: model)
        webView.navigationDelegate = coordinator
        defer { webView.navigationDelegate = nil }
        // An off-screen web view's content process can be suspended, so host it in a window as the app does.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.frame = window.bounds
        window.addSubview(webView)
        window.isHidden = false
        defer { window.isHidden = true }

        let first = server.url("/page/spa.html")
        webView.load(URLRequest(url: first))
        try await waitUntil("first page loaded, url=\(String(describing: model.url))") { model.url == first && !model.isLoading }
        XCTAssertFalse(model.canGoBack)
        model.add(MediaCandidate(url: URL(string: "http://127.0.0.1:9/ep1.m3u8")!, sourcePageURL: first))
        XCTAssertEqual(model.candidates.count, 1)

        // Same call the fixture's link makes.
        webView.evaluateJavaScript("History.prototype.pushState.call(history, null, '', '/page/spa.html?ep=2'); document.title = 'SPA Episode 2'; 0",
                                   completionHandler: nil)
        try await waitUntil("router navigation observed, url=\(String(describing: model.url)) title=\(model.pageTitle)") {
            model.url?.absoluteString.hasSuffix("/page/spa.html?ep=2") == true && model.pageTitle == "SPA Episode 2"
        }
        XCTAssertEqual(model.addressText, model.url?.absoluteString)
        XCTAssertTrue(model.candidates.isEmpty, "the previous episode's videos are cleared")
        try await waitUntil("Back enabled") { model.canGoBack }
    }

    private func waitUntil(_ description: @autoclosure () -> String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("\(description()) — not met within \(timeout) s") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A page's player fetches the master and its separate audio playlist; only the master is a complete video.
    func testAudioRenditionIsHiddenBehindItsMasterPlaylist() async throws {
        let server = try LocalMediaServer()
        try server.start()
        defer { server.stop() }
        let model = makeModel()
        let page = server.url("/page/separate-audio.html")
        model.pageDidChange(to: page, force: true)
        model.add(MediaCandidate(url: server.url("/hls/audio-only.m3u8"), sourcePageURL: page, kind: .hls))
        model.add(MediaCandidate(url: server.url("/hls/separate-audio-master.m3u8"), sourcePageURL: page, kind: .hls))
        try await waitUntil("master validated, statuses=\(model.statuses.values)") {
            model.candidates.count == 1 && model.readyCount == 1
        }
        XCTAssertEqual(model.candidates.first?.url.lastPathComponent, "separate-audio-master.m3u8")
        model.add(MediaCandidate(url: server.url("/hls/audio-only.m3u8"), sourcePageURL: page, kind: .hls))
        XCTAssertEqual(model.candidates.count, 1)
    }

    /// KVO closures, the script message handler and the web view must not keep the model alive.
    func testModelAndWebViewAreReleased() async throws {
        weak var weakModel: BrowserViewModel?
        weak var weakWebView: WKWebView?
        weak var weakDiscovery: MediaDiscoveryController?
        do {
            let model = makeModel()
            let webView = model.makeWebView()
            let coordinator = BrowserView.Coordinator(model: model)
            webView.navigationDelegate = coordinator
            // Hosted so the content process isn't suspended; a freshly booted CI simulator starts it slowly.
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            webView.frame = window.bounds
            window.addSubview(webView)
            window.isHidden = false
            webView.loadHTMLString("<title>Release</title><p>x</p>", baseURL: URL(string: "https://release.example/"))
            try await waitUntil("page loaded", timeout: 30) { model.pageTitle == "Release" }
            weakModel = model
            weakWebView = webView
            weakDiscovery = model.discovery
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            window.isHidden = true
        }
        try await waitUntil("model, web view and discovery released") { weakModel == nil && weakWebView == nil && weakDiscovery == nil }
    }
}
