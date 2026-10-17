import Foundation
import WebKit

final class MediaDiscoveryController: NSObject, WKScriptMessageHandler {
    var onCandidate: ((MediaCandidate) -> Void)?
    var onNavigation: ((URL?) -> Void)?
    var onFragment: (() -> Void)?
    var onSubtitles: (([SubtitleTrack]) -> Void)?
    /// A poster image; `fromPlayer` is a `<video poster>`, otherwise the page's preview image.
    var onPoster: ((_ url: URL, _ fromPlayer: Bool) -> Void)?
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
      let reportedTracks = new Set();
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
      const postTracks = tracks => {
        if (!tracks.length) return;
        const key = tracks.map(t => t.url + '|' + t.label).join('\n');
        if (reportedTracks.has(key)) return;
        reportedTracks.add(key);
        post({ event: 'subtitles', tracks, documentURL: location.href });
      };
      const absoluteURL = src => {
        if (!src || typeof src !== 'string' || src.startsWith('blob:') || src.startsWith('data:')) return null;
        try { return new URL(src, document.baseURI).href; } catch (_) { return null; }
      };
      // Players such as Plyr show subtitles from <track> files that aren't part of the
      // stream; report them with their labels so a download can keep them.
      const reportTracks = video => {
        if (!video || !video.querySelectorAll) return;
        const tracks = [];
        video.querySelectorAll('track').forEach(track => {
          const kind = (track.getAttribute('kind') || 'subtitles').toLowerCase();
          if (kind !== 'subtitles' && kind !== 'captions') return;
          const url = absoluteURL(track.getAttribute('src'));
          if (!url) return;
          tracks.push({ url, label: track.getAttribute('label') || '', language: track.getAttribute('srclang') || '',
                        isDefault: track.hasAttribute('default') });
        });
        postTracks(tracks);
      };
      // JW Player keeps its subtitle list in its playlist, not in <track> elements, and
      // fetches only the language being shown.
      const reportPlayerTracks = () => {
        try {
          if (typeof window.jwplayer !== 'function') return;
          const player = window.jwplayer();
          const item = player && player.getPlaylistItem && player.getPlaylistItem();
          const tracks = [];
          ((item && item.tracks) || []).forEach(t => {
            const kind = String((t && t.kind) || 'captions').toLowerCase();
            const url = t && absoluteURL(t.file);
            if (!url || (kind !== 'captions' && kind !== 'subtitles')) return;
            tracks.push({ url, label: t.label || '', language: t.language || '', isDefault: !!t.default });
          });
          postTracks(tracks);
        } catch (_) {}
      };
      // Other players fetch a whole WebVTT or SRT file by script. HLS subtitle segments are
      // .vtt too, but carry X-TIMESTAMP-MAP and are saved with the stream, so they're skipped.
      const reportSubtitleFile = (url, contentType, body) => {
        const type = (contentType || '').toLowerCase();
        if (!type.includes('text/vtt') && !type.includes('subrip') && !/\.(vtt|srt)(?:[?#]|$)/i.test(url || '')) return;
        if (typeof body !== 'string' || body.includes('X-TIMESTAMP-MAP')) return;
        const text = body.replace(/^\uFEFF/, '').trimStart();
        if (!text.startsWith('WEBVTT') && !/^\d+\s*\r?\n\d\d:\d\d/.test(text)) return;
        const absolute = absoluteURL(url);
        if (absolute) postTracks([{ url: absolute, label: '', language: '', isDefault: false }]);
      };
      // Some players fetch a JSON list of subtitle files and download only the language picked:
      // ***REMOVED***'s [{ label, file }] ("Arabic", "Arabic2", …) and ***REMOVED***'s [{ url, display, language,
      // format }]. One file per language is kept.
      const reportSubtitleList = (url, contentType, body) => {
        if (!/json/i.test(contentType || '') || body === null || body === undefined) return;
        const subtitleRequest = /sub|caption|***REMOVED***/i.test(url || '');
        let data = body;
        if (typeof body === 'string') {
          if (body.length > 2000000 || (!subtitleRequest && !/\.(vtt|srt)\b|"format"\s*:\s*"(srt|vtt)"/i.test(body))) return;
          try { data = JSON.parse(body); } catch (_) { return; }
        }
        const tracks = [];
        const languages = new Set();
        const visit = (value, depth) => {
          if (!value || typeof value !== 'object' || depth > 5 || tracks.length >= 60) return;
          if (Array.isArray(value)) { value.forEach(item => visit(item, depth + 1)); return; }
          const file = [value.file, value.url, value.src].find(v => typeof v === 'string' && /^https?:/i.test(v));
          const format = String(value.format || '').toLowerCase();
          const label = String(value.label || value.display || '').replace(/\s*\d+$/, '');
          const language = String(value.language || value.lang || value.srclang || '');
          if (file && !/\.(m3u8|mp4|m4v|webm|ts|jpe?g|png|webp)(?:[?#]|$)/i.test(file) &&
              (/\.(vtt|srt)(?:[?#]|$)/i.test(file) || format === 'srt' || format === 'vtt' || (subtitleRequest && (label || language)))) {
            const key = (language || label).toLowerCase() + (value.isHearingImpaired ? ' sdh' : '');
            if (!languages.has(key)) {
              languages.add(key);
              tracks.push({ url: file, label: label + (value.isHearingImpaired ? ' (SDH)' : ''), language, isDefault: !!value.default });
            }
            return;
          }
          Object.values(value).forEach(item => visit(item, depth + 1));
        };
        visit(data, 0);
        postTracks(tracks);
      };
      // Artwork for the library: a player's poster, or the page's preview image.
      let reportedPosters = new Set();
      const reportPoster = (src, kind) => {
        if (!src || src.startsWith('data:') || src.startsWith('blob:')) return;
        let url;
        try { url = new URL(src, document.baseURI).href; } catch (_) { return; }
        if (reportedPosters.has(url)) return;
        reportedPosters.add(url);
        post({ event: 'poster', url, kind, documentURL: location.href });
      };
      const reportPagePoster = () => {
        if (window !== window.top || !document.querySelector) return;
        const meta = document.querySelector('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"]');
        if (meta) reportPoster(meta.getAttribute('content'), 'page');
      };
      const inspect = node => {
        if (!node) return;
        const tag = (node.tagName || '').toUpperCase();
        if (tag === 'TRACK') { reportTracks(node.parentElement); return; }
        if (tag === 'VIDEO') {
          reportTracks(node);
          if (node.getAttribute) reportPoster(node.getAttribute('poster'), 'video');
        }
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
        reportedTracks = new Set();
        reportedPosters = new Set();
        document.querySelectorAll('video,audio,source').forEach(inspect);
        reportPlayerTracks();
        reportPagePoster();
        scanResources();
        document.querySelectorAll('iframe').forEach(f => { try { f.contentWindow.postMessage({ __vdaRescan: true }, '*'); } catch (_) {} });
      };
      window.addEventListener('message', event => { if (event.data && event.data.__vdaRescan === true) window.__vdaRescan(); });
      document.querySelectorAll('video,audio,source').forEach(inspect);
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', reportPagePoster); else reportPagePoster();
      document.addEventListener('loadedmetadata', event => { inspect(event.target); reportPlayerTracks(); }, true);
      document.addEventListener('play', event => { inspect(event.target); reportPlayerTracks(); }, true);
      document.addEventListener('pointerdown', activate, true);
      document.addEventListener('touchstart', activate, true);
      document.addEventListener('keydown', activate, true);
      new MutationObserver(mutations => mutations.forEach(m => {
        if (m.type === 'attributes') {
          const tag = (m.target.tagName || '').toUpperCase();
          if (tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE' || tag === 'TRACK') inspect(m.target);
        } else {
          m.addedNodes.forEach(scheduleMediaScan);
        }
      })).observe(document.documentElement || document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
      const notifyNavigation = () => {
        seen = new Set(); reportedTracks = new Set(); reportedPosters = new Set(); reportedFragment = false;
        post({ event: 'navigation', url: location.href });
        // Client-side routers update the preview image after the address.
        setTimeout(reportPagePoster, 800);
      };
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
          try {
            result.then(response => {
              try {
                const type = response.headers.get('content-type');
                report(response.url, type, 'fetch');
                if (/\.(vtt|srt)(?:[?#]|$)/i.test(response.url) || /text\/vtt|subrip|json/i.test(type || '')) {
                  response.clone().text().then(text => {
                    reportSubtitleFile(response.url, type, text);
                    reportSubtitleList(response.url, type, text);
                  }, () => {});
                }
              } catch (_) {}
            }, () => {});
          } catch (_) {}
          return result;
        };
      }
      if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype) {
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function() {
          try {
            this.addEventListener('load', () => {
              try {
                const type = this.getResponseHeader('content-type');
                report(this.responseURL, type, 'xhr');
                if (this.responseType === '' || this.responseType === 'text') {
                  reportSubtitleFile(this.responseURL, type, this.responseText);
                  reportSubtitleList(this.responseURL, type, this.responseText);
                } else if (this.responseType === 'json') {
                  reportSubtitleList(this.responseURL, type, this.response);
                }
              } catch (_) {}
            });
          } catch (_) {}
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

    /// Starts muted playback so players reveal their streams: for the hidden browser that finds
    /// episodes, and in Debug builds for site checks (`-DiagnosticsAutoplay`).
    static let autoplaySource = #"""
    (() => {
      const tryPlay = () => {
        // A player that is already going is left alone: some overlays toggle play and pause.
        const videos = Array.from(document.querySelectorAll('video'));
        if (videos.some(v => !v.paused && v.currentTime > 0)) return;
        videos.forEach(v => { try { v.muted = true; const p = v.play(); if (p) p.catch(() => {}); } catch (_) {} });
        // Overlay play buttons of common players, and of site templates (***REMOVED***, ***REMOVED***: #player .play).
        const button = document.querySelector('.jw-icon-display, .jw-display-icon-container, .vjs-big-play-button, .plyr__control--overlaid, media-play-button, [aria-label="Play"], .play-button, #play, #player .play, #w-player .play, .player-wrapper .play, .btn-play, .play-btn, [class*="big-play"]');
        if (button) { try { button.click(); } catch (_) {} }
      };
      [2000, 5000, 10000, 20000, 30000].forEach(delay => setTimeout(tryPlay, delay));
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

        if dictionary["event"] as? String == "poster" {
            let documentURL = (dictionary["documentURL"] as? String).flatMap(URL.init(string:))
            if let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               !MediaDiscovery.isStale(documentURL: documentURL, isMainFrame: isMainFrame, currentPageURL: mainURL) {
                onPoster?(url, dictionary["kind"] as? String == "video")
            }
            return
        }
        if dictionary["event"] as? String == "subtitles" {
            let tracks = SubtitleTrack.tracks(from: dictionary, frameURL: frameURL)
            diagnostics?.record(event: "subtitles", url: (dictionary["documentURL"] as? String) ?? "", frameURL: frameURL, isMainFrame: isMainFrame,
                                note: "\(tracks.count) tracks: " + tracks.map(\.displayName).joined(separator: ", "))
            let documentURL = (dictionary["documentURL"] as? String).flatMap(URL.init(string:))
            if !tracks.isEmpty, !MediaDiscovery.isStale(documentURL: documentURL, isMainFrame: isMainFrame, currentPageURL: mainURL) {
                onSubtitles?(tracks)
            }
            return
        }
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
