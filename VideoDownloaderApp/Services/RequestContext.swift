import Foundation

/// Browser headers and cookies for one media request; never persisted.
struct RequestContext: Equatable {
    var cookies: [HTTPCookie]
    var userAgent: String?
    var referer: URL?

    /// Cookies from `all` that RFC 6265 would send to `url` at `now`.
    static func cookies(from all: [HTTPCookie], for url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return [] }
        let path = requestPath(of: url)
        return all.filter { cookie in
            if let expires = cookie.expiresDate, expires < now { return false }
            if cookie.isSecure && scheme != "https" { return false }
            return domainMatches(cookie.domain, host: host) && pathMatches(cookie.path, requestPath: path)
        }
    }

    func apply(to request: inout URLRequest, now: Date = Date()) {
        if let url = request.url {
            let matching = Self.cookies(from: cookies, for: url, now: now)
            for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
    }

    /// Strips the Cookie header on cross-host redirects; on same-host redirects re-applies only cookies matching the new URL.
    static func redirectedRequest(_ newRequest: URLRequest, from original: URLRequest, context: RequestContext?, now: Date = Date()) -> URLRequest {
        var request = newRequest
        let oldHost = original.url?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        if oldHost == nil || oldHost != newHost {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            context.map { RequestContext(cookies: [], userAgent: $0.userAgent, referer: $0.referer) }?.apply(to: &request, now: now)
        } else if let context {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            context.apply(to: &request, now: now)
        }
        for field in ["User-Agent", "Referer"] where request.value(forHTTPHeaderField: field) == nil {
            if let value = original.value(forHTTPHeaderField: field) { request.setValue(value, forHTTPHeaderField: field) }
        }
        return request
    }

    private static func domainMatches(_ cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.lowercased()
        guard domain.hasPrefix(".") else { return domain == host }
        let base = String(domain.dropFirst())
        guard !base.isEmpty else { return false }
        if host == base { return true }
        // Domain cookies never apply to IP hosts other than exact matches, nor from single-label (TLD-like) domains.
        guard !isIPAddress(host), base.contains(".") else { return false }
        return host.hasSuffix("." + base)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// RFC 6265 §5.1.4.
    private static func pathMatches(_ cookiePath: String, requestPath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        return requestPath.dropFirst(cookiePath.count).first == "/"
    }

    private static func requestPath(of url: URL) -> String {
        let encoded = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
        let path = encoded.removingPercentEncoding ?? encoded
        return path.hasPrefix("/") ? path : "/"
    }
}
