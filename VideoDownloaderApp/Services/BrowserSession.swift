import Foundation
import WebKit

@MainActor
enum BrowserSession {
    private static let userAgentKey = "BrowserSession.userAgent"

    static var userAgent: String? {
        get { UserDefaults.standard.string(forKey: userAgentKey) }
        set { UserDefaults.standard.set(newValue, forKey: userAgentKey) }
    }

    static func requestContext(for mediaURL: URL, referer: URL?) async -> RequestContext {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        // Child playlists and segments can be on other hosts, so keep all cookies and scope them per request.
        return RequestContext(cookies: cookies, userAgent: userAgent,
                              referer: referer.map { refererValue(for: $0, requesting: mediaURL) })
    }

    /// Mirrors the browser's default `strict-origin-when-cross-origin` policy: cross-origin requests only see the origin.
    static func refererValue(for page: URL, requesting target: URL) -> URL {
        guard page.scheme != target.scheme || page.host != target.host || page.port != target.port,
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return page }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? page
    }
}
