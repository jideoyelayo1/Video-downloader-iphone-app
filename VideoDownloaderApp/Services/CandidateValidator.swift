import Foundation

struct ProbeResult: Equatable {
    var kind: MediaKind
    var expectedBytes: Int64?
    /// Master-playlist variants, highest bandwidth first; empty for files and single-rendition streams.
    var variants: [HLSVariant] = []
    var duration: Double?
}

enum CandidateStatus: Equatable {
    case checking
    case ready(ProbeResult)
    case unavailable(DownloadError)

    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// Checks a discovered URL before it is offered for download.
struct CandidateValidator {
    static let refererRequiredMessage = "This stream only plays with the player's Referer header, which iOS offline HLS downloads can't send."

    let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
    }

    func validate(_ candidate: MediaCandidate, context: RequestContext?) async -> CandidateStatus {
        do {
            if candidate.kind == .hls { return try await validateHLS(candidate.url, context: context) }
            return try await validateFile(candidate, context: context)
        } catch let error as DownloadError {
            return .unavailable(error)
        } catch {
            return .unavailable(DownloadError.from(error))
        }
    }

    // MARK: Files

    private func validateFile(_ candidate: MediaCandidate, context: RequestContext?) async throws -> CandidateStatus {
        let (prefix, response) = try await fetchPrefix(candidate.url, context: context)
        if let failure = DownloadResponseValidation.failure(statusCode: response.statusCode, mimeType: response.mimeType, prefixData: prefix) {
            // Extension-less manifests are only recognisable by their content.
            if failure == .hlsPlaylistAsFile { return try await validateHLS(candidate.url, context: context) }
            return .unavailable(failure)
        }
        let kind = MediaKind(contentType: response.mimeType) ?? (candidate.kind == .unknown ? .video : candidate.kind)
        return .ready(ProbeResult(kind: kind, expectedBytes: Self.totalLength(of: response)))
    }

    /// Reads at most 4 KB, even from servers that ignore the Range header.
    private func fetchPrefix(_ url: URL, context: RequestContext?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        context?.apply(to: &request)
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectScoper(context: context, original: request))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw DownloadError.other("The server didn't return an HTTP response.") }
        var data = Data()
        if (200..<300).contains(http.statusCode) {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4096 { break }
            }
        }
        return (data, http)
    }

    static func totalLength(of response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let value = Int64(total) {
            return value
        }
        return response.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    // MARK: HLS

    /// AVFoundation sends cookies and User-Agent but no Referer, so streams are probed the same way.
    private func validateHLS(_ url: URL, context: RequestContext?) async throws -> CandidateStatus {
        var avContext = context
        avContext?.referer = nil
        let (text, finalURL) = try await fetchPlaylist(url, context: avContext, fullContext: context)
        guard let manifest = HLSManifest.parse(text, baseURL: finalURL) else { return .unavailable(.notVideo) }
        switch manifest {
        case .master(let variants):
            guard let best = variants.first else { return .unavailable(.notVideo) }
            let (mediaText, mediaURL) = try await fetchPlaylist(best.url, context: avContext, fullContext: context)
            guard case .media(let isFinite, let drm, _, let duration)? = HLSManifest.parse(mediaText, baseURL: mediaURL) else {
                return .unavailable(.notVideo)
            }
            if drm { return .unavailable(.protectedStream) }
            if !isFinite { return .unavailable(.liveStream) }
            try await checkFirstSegment(of: mediaText, baseURL: mediaURL, context: avContext, fullContext: context)
            let bytes = best.bandwidth.map { Int64(Double($0) / 8 * duration) }
            return .ready(ProbeResult(kind: .hls, expectedBytes: bytes, variants: variants, duration: duration))
        case .media(let isFinite, let drm, _, let duration):
            if drm { return .unavailable(.protectedStream) }
            if !isFinite { return .unavailable(.liveStream) }
            try await checkFirstSegment(of: text, baseURL: finalURL, context: avContext, fullContext: context)
            return .ready(ProbeResult(kind: .hls, duration: duration))
        }
    }

    private func fetchPlaylist(_ url: URL, context: RequestContext?, fullContext: RequestContext?) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        context?.apply(to: &request)
        let (data, response) = try await session.data(for: request, delegate: RedirectScoper(context: context, original: request))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = DownloadError.from(statusCode: status) {
            try await throwRefererBlockerIfNeeded(url, status: status, fullContext: fullContext)
            throw error
        }
        guard data.count < 4_000_000, let text = String(data: data, encoding: .utf8) else { throw DownloadError.notVideo }
        return (text, response.url ?? url)
    }

    /// Segments are often protected separately from the playlist, so the first one is checked too.
    private func checkFirstSegment(of playlist: String, baseURL: URL, context: RequestContext?, fullContext: RequestContext?) async throws {
        guard let line = playlist.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              let segmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else { return }
        let (prefix, response) = try await fetchPrefix(segmentURL, context: context)
        if let error = DownloadError.from(statusCode: response.statusCode) {
            try await throwRefererBlockerIfNeeded(segmentURL, status: response.statusCode, fullContext: fullContext)
            throw error
        }
        // A successful status is not enough: a CDN or anti-bot layer can return
        // an HTML challenge (or another playlist) at the segment URL. Do not mark
        // the HLS candidate ready unless the first segment looks like media data.
        let leadingText = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if leadingText.hasPrefix("<!doctype html") || leadingText.hasPrefix("<html") || leadingText.hasPrefix("<script") || leadingText.hasPrefix("#extm3u") {
            throw DownloadError.notVideo
        }
    }

    /// On 401/403, retries with the Referer; if that succeeds the stream is blocked by a platform limitation, not an expired link.
    private func throwRefererBlockerIfNeeded(_ url: URL, status: Int, fullContext: RequestContext?) async throws {
        guard [401, 403].contains(status), fullContext?.referer != nil else { return }
        let (_, response) = try await fetchPrefix(url, context: fullContext)
        if (200..<300).contains(response.statusCode) { throw DownloadError.other(Self.refererRequiredMessage) }
    }
}

/// Keeps cookies from following a redirect to another host.
final class RedirectScoper: NSObject, URLSessionTaskDelegate {
    let context: RequestContext?
    let original: URLRequest

    init(context: RequestContext?, original: URLRequest) {
        self.context = context
        self.original = original
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RequestContext.redirectedRequest(request, from: task.originalRequest ?? original, context: context))
    }
}
