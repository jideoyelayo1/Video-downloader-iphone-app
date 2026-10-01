import Foundation
import WebKit

final class MediaDiscoveryController: NSObject, WKScriptMessageHandler {
    var onCandidate: ((MediaCandidate) -> Void)?
    var onNavigation: ((URL?) -> Void)?
    var onFragment: (() -> Void)?
    var diagnostics: DiagnosticsLog?
    weak var webView: WKWebView?

    static let source = #"""
    (() => {
      if (window.__vdaDiscovery) return;
      window.__vdaDiscovery = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mediaDiscovery;
      if (!handler) return;
      const post = payload => { try { handler.postMessage(payload); } catch (_) {} };
      let seen = new Set();
      let reportedFragment = false;
      let interactionTime = null;
      let pendingMediaNodes = new Set();
      let mediaScanTimer = null;
      // Network resources include ad clips and tracking previews. A playlist may be
      // prepared before playback, but ordinary file requests must follow a real tap.
      const relevantResource = (url, startedAt) => {
        // Resource timing also contains images, scripts and ad requests. Avoid
        // parsing each of those URLs on busy pages.
        if (!/\.(m3u8|mp4|m4v|mov|webm|mkv|m4s|ts)(?:[?#]|$)/i.test(url)) return false;
        let path;
        try { path = new URL(url, document.baseURI).pathname.toLowerCase(); } catch (_) { return false; }
        if (path.endsWith('.m3u8')) return true;
        return interactionTime !== null && startedAt >= interactionTime - 500;
      };
      const activate = event => {
        if (event && event.isTrusted === false) return;
        if (interactionTime !== null) return;
        interactionTime = performance.now();
        // One catch-up scan covers resources loaded before the first tap. New
        // requests are handled by PerformanceObserver without rescanning on
        // every subsequent interaction.
        scanResources();
      };
      const classify = (absolute, contentType) => {
        const type = (contentType || '').toLowerCase();
        if (type.includes('mpegurl')) return 'hls';
        const pathname = new URL(absolute).pathname.toLowerCase();
        if (pathname.endsWith('.m3u8')) return 'hls';
        if (pathname.match(/\.(mp4|m4v|mov|webm|mkv|ts)$/)) return 'video';
        if (type.startsWith('video/') && !type.startsWith('video/mp2t') && !type.startsWith('video/iso.segment')) return 'video';
        return 'unknown';
      };
      const send = (url, hint, mediaElement = false, contentType = null, via = 'element') => {
        if (!url || typeof url !== 'string' || url.startsWith('blob:') || url.startsWith('data:')) return;
        let absolute;
        try { absolute = new URL(url, document.baseURI).href; } catch (_) { return; }
        const path = new URL(absolute).pathname.toLowerCase();
        if (path.endsWith('.m4s') || path.endsWith('.ts')) {
          if (!reportedFragment) { reportedFragment = true; post({ event: 'fragment', url: absolute }); }
          return;
        }
        const type = (contentType || '').toLowerCase();
        if (type.startsWith('video/iso.segment') || type.startsWith('video/mp2t')) {
          if (!reportedFragment) { reportedFragment = true; post({ event: 'fragment', url: absolute }); }
          return;
        }
        const kind = classify(absolute, contentType);
        if (!mediaElement && kind === 'unknown') return;
        // A playlist is often seen twice (its XHR response and its resource
        // timing entry); report it again only if it is classified differently.
        const key = absolute + '|' + mediaElement + '|' + kind;
        if (seen.has(key)) return;
        seen.add(key);
        post({ url: absolute, kind, title: document.title || 'Discovered video', documentURL: location.href,
               quality: hint || null, mediaElement, contentType, via });
      };
      const report = (url, contentType, via) => {
        if (!url) return;
        if (window.__vdaDiagnostics) post({ event: 'response', url, contentType: contentType || null, via });
        const type = (contentType || '').toLowerCase();
        if (type.includes('mpegurl') ||
            (interactionTime !== null && type.startsWith('video/'))) send(url, null, false, contentType, via);
      };
      const inspect = node => {
        if (!node) return;
        const tag = (node.tagName || '').toUpperCase();
        const isMedia = tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE';
        if (isMedia && node.currentSrc) send(node.currentSrc, node.getAttribute('data-quality'), true);
        if (isMedia && node.src) send(node.src, node.getAttribute('data-quality'), true);
        if (tag === 'SOURCE' && node.src) send(node.src, node.getAttribute('size') || node.getAttribute('label'), true, node.getAttribute('type'));
        if (node.querySelectorAll) node.querySelectorAll('video,audio,source').forEach(inspect);
      };
      const scheduleMediaScan = node => {
        if (!node || node.nodeType !== 1) return;
        pendingMediaNodes.add(node);
        if (mediaScanTimer !== null) return;
        mediaScanTimer = setTimeout(() => {
          mediaScanTimer = null;
          pendingMediaNodes.forEach(inspect);
          pendingMediaNodes.clear();
        }, 100);
      };
      // Diagnostics come only from the PerformanceObserver below, which is
      // buffered and so already reports every entry once. Re-posting the whole
      // buffer here would repeat every request on each tap or Refresh.
      const scanResources = () => {
        try {
          performance.getEntriesByType('resource').forEach(e => {
            if (relevantResource(e.name, e.startTime)) send(e.name, null, false, null, 'resource');
          });
        } catch (_) {}
      };
      // Rescans this document, then asks child frames (often cross-origin players) to do the same.
      window.__vdaRescan = () => {
        seen = new Set();
        document.querySelectorAll('video,audio,source').forEach(inspect);
        scanResources();
        document.querySelectorAll('iframe').forEach(f => { try { f.contentWindow.postMessage({ __vdaRescan: true }, '*'); } catch (_) {} });
      };
      window.addEventListener('message', event => { if (event.data && event.data.__vdaRescan === true) window.__vdaRescan(); });
      document.querySelectorAll('video,audio,source').forEach(inspect);
      document.addEventListener('loadedmetadata', event => inspect(event.target), true);
      document.addEventListener('play', event => inspect(event.target), true);
      document.addEventListener('pointerdown', activate, true);
      document.addEventListener('touchstart', activate, true);
      document.addEventListener('keydown', activate, true);
      new MutationObserver(mutations => mutations.forEach(m => {
        if (m.type === 'attributes') {
          const tag = (m.target.tagName || '').toUpperCase();
          if (tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE') inspect(m.target);
        } else {
          m.addedNodes.forEach(scheduleMediaScan);
        }
      })).observe(document.documentElement || document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
      const notifyNavigation = () => { seen = new Set(); reportedFragment = false; post({ event: 'navigation', url: location.href }); };
      window.addEventListener('popstate', notifyNavigation);
      window.addEventListener('hashchange', notifyNavigation);
      const pushState = history.pushState;
      history.pushState = function() { const result = pushState.apply(this, arguments); notifyNavigation(); return result; };
      const replaceState = history.replaceState;
      history.replaceState = function() { const result = replaceState.apply(this, arguments); notifyNavigation(); return result; };
      // Players built on hls.js/Shaka fetch extension-less manifests; only the response type identifies them.
      if (typeof window.fetch === 'function') {
        const originalFetch = window.fetch;
        window.fetch = function() {
          const result = originalFetch.apply(this, arguments);
          try { result.then(response => { try { report(response.url, response.headers.get('content-type'), 'fetch'); } catch (_) {} }, () => {}); } catch (_) {}
          return result;
        };
      }
      if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype) {
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function() {
          try { this.addEventListener('load', () => { try { report(this.responseURL, this.getResponseHeader('content-type'), 'xhr'); } catch (_) {} }); } catch (_) {}
          return originalSend.apply(this, arguments);
        };
      }
      scanResources();
      try {
        new PerformanceObserver(list => list.getEntries().forEach(e => {
          if (window.__vdaDiagnostics && ['xmlhttprequest', 'fetch', 'video', 'audio', 'other'].includes(e.initiatorType)) {
            post({ event: 'resource', url: e.name, via: e.initiatorType });
          }
          if (relevantResource(e.name, e.startTime)) send(e.name, null, false, null, 'resource');
        })).observe({ type: 'resource', buffered: true });
      } catch (_) {}
    })();
    """#

    /// Debug-only helper for the site compatibility gate: starts muted playback so players reveal their streams.
    static let autoplaySource = #"""
    (() => {
      const tryPlay = () => {
        document.querySelectorAll('video').forEach(v => { try { v.muted = true; const p = v.play(); if (p) p.catch(() => {}); } catch (_) {} });
        const button = document.querySelector('.jw-icon-display, .jw-display-icon-container, .vjs-big-play-button, .plyr__control--overlaid, media-play-button, [aria-label="Play"], .play-button, #play');
        if (button) { try { button.click(); } catch (_) {} }
      };
      [2000, 5000, 10000].forEach(delay => setTimeout(tryPlay, delay));
    })();
    """#

    func userScripts(diagnosticsEnabled: Bool, autoplay: Bool) -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        if diagnosticsEnabled {
            scripts.append(WKUserScript(source: "window.__vdaDiagnostics = true;", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        scripts.append(WKUserScript(source: Self.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if autoplay {
            scripts.append(WKUserScript(source: Self.autoplaySource, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        return scripts
    }

    /// Asks the page and its player frames to report their media again.
    func rescan() {
        webView?.evaluateJavaScript("window.__vdaRescan && window.__vdaRescan()")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MediaDiscovery.messageName,
              let dictionary = message.body as? [String: Any],
              let mainURL = webView?.url else { return }
        let isMainFrame = message.frameInfo.isMainFrame
        let frameURL = message.frameInfo.request.url
        let rawURL = dictionary["url"] as? String ?? ""

        if let event = dictionary["event"] as? String {
            diagnostics?.record(event: event, url: rawURL, frameURL: frameURL, isMainFrame: isMainFrame,
                                contentType: dictionary["contentType"] as? String, note: dictionary["via"] as? String)
            if event == "navigation", isMainFrame { onNavigation?(URL(string: rawURL)) }
            if event == "fragment" { onFragment?() }
            return
        }

        let documentURL = (dictionary["documentURL"] as? String).flatMap(URL.init(string:))
        let stale = MediaDiscovery.isStale(documentURL: documentURL, isMainFrame: isMainFrame, currentPageURL: mainURL)
        var payload = dictionary
        // Player iframes usually have generic titles; the page title names the episode.
        if !isMainFrame, let pageTitle = webView?.title, !pageTitle.isEmpty { payload["title"] = pageTitle }
        let candidate = stale ? nil : MediaDiscovery.candidate(from: payload, sourcePageURL: mainURL, frameURL: frameURL, isMainFrame: isMainFrame)
        diagnostics?.record(event: "media", url: rawURL, frameURL: frameURL, isMainFrame: isMainFrame,
                            contentType: dictionary["contentType"] as? String,
                            note: "\(dictionary["via"] as? String ?? "element") → " + (stale ? "stale, ignored" : candidate.map { "candidate (\($0.kind.rawValue))" } ?? "filtered"))
        if let candidate { onCandidate?(candidate) }
    }
}

/// Breaks the retain cycle WKUserContentController would otherwise form with its handler.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
