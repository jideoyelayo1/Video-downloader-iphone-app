import XCTest
@testable import VideoDownloaderApp

final class RequestContextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v", .domain: domain, .path: path]
        if secure { props[.secure] = "TRUE" }
        if let expires { props[.expires] = expires }
        return HTTPCookie(properties: props)!
    }

    private func names(_ cookies: [HTTPCookie], _ url: String) -> [String] {
        RequestContext.cookies(from: cookies, for: URL(string: url)!, now: now).map(\.name).sorted()
    }

    func testDomainCookieMatchesHostAndSubdomainsButNotSiblings() {
        let c = [cookie("d", domain: ".example.com")]
        XCTAssertEqual(names(c, "https://example.com/"), ["d"])
        XCTAssertEqual(names(c, "https://a.example.com/"), ["d"])
        XCTAssertEqual(names(c, "https://x.y.example.com/"), ["d"])
        XCTAssertEqual(names(c, "https://badexample.com/"), [])
        XCTAssertEqual(names(c, "https://example.com.evil.net/"), [])
        XCTAssertEqual(names(c, "https://A.EXAMPLE.COM/"), ["d"])
    }

    func testHostOnlyCookieDoesNotGoToSubdomains() {
        let c = [cookie("h", domain: "example.com")]
        XCTAssertEqual(names(c, "https://example.com/"), ["h"])
        XCTAssertEqual(names(c, "https://Example.COM/"), ["h"])
        XCTAssertEqual(names(c, "https://a.example.com/"), [])
        XCTAssertEqual(names(c, "https://badexample.com/"), [])
    }

    func testSetCookieParsedCookiesKeepHostOnlySemantics() {
        let origin = URL(string: "https://www.example.com/")!
        let hostOnly = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "h=1; Path=/"], for: origin)
        let domain = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "d=1; Domain=example.com; Path=/"], for: origin)
        XCTAssertEqual(names(hostOnly + domain, "https://cdn.example.com/v.mp4"), ["d"])
        XCTAssertEqual(names(hostOnly + domain, "https://www.example.com/v.mp4"), ["d", "h"])
    }

    func testTLDLikeDomainCookieRejected() {
        XCTAssertEqual(names([cookie("t", domain: ".com")], "https://example.com/"), [])
    }

    func testIPHostsRequireExactMatch() {
        XCTAssertEqual(names([cookie("ip", domain: "192.168.1.10")], "http://192.168.1.10/v"), ["ip"])
        XCTAssertEqual(names([cookie("ip", domain: ".168.1.10")], "http://192.168.1.10/v"), [])
    }

    func testPathMatching() {
        let c = [cookie("p", domain: "example.com", path: "/a")]
        XCTAssertEqual(names(c, "https://example.com/a"), ["p"])
        XCTAssertEqual(names(c, "https://example.com/a/b"), ["p"])
        XCTAssertEqual(names(c, "https://example.com/a/"), ["p"])
        XCTAssertEqual(names(c, "https://example.com/ab"), [])
        XCTAssertEqual(names(c, "https://example.com/"), [])
        XCTAssertEqual(names(c, "https://example.com"), [])
        let slash = [cookie("s", domain: "example.com", path: "/a/")]
        XCTAssertEqual(names(slash, "https://example.com/a/b"), ["s"])
        XCTAssertEqual(names(slash, "https://example.com/a"), [])
        XCTAssertEqual(names([cookie("r", domain: "example.com")], "https://example.com"), ["r"])
    }

    func testSecureCookiesOnlyOverHTTPS() {
        let c = [cookie("s", domain: "example.com", secure: true), cookie("p", domain: "example.com")]
        XCTAssertEqual(names(c, "https://example.com/"), ["p", "s"])
        XCTAssertEqual(names(c, "http://example.com/"), ["p"])
    }

    func testExpiredCookiesDropped() {
        let c = [cookie("old", domain: "example.com", expires: now.addingTimeInterval(-1)),
                 cookie("new", domain: "example.com", expires: now.addingTimeInterval(60)),
                 cookie("session", domain: "example.com")]
        XCTAssertEqual(names(c, "https://example.com/"), ["new", "session"])
    }

    func testNonHTTPSchemesGetNothing() {
        let c = [cookie("x", domain: "example.com")]
        XCTAssertEqual(names(c, "ftp://example.com/"), [])
        XCTAssertEqual(names(c, "file:///tmp/a.mp4"), [])
    }

    func testApplySetsHeadersWithFilteredCookies() {
        let context = RequestContext(cookies: [cookie("a", domain: ".example.com"), cookie("b", domain: "other.com")],
                                     userAgent: "UA/1", referer: URL(string: "https://example.com/watch?v=1"))
        var request = URLRequest(url: URL(string: "https://cdn.example.com/v.mp4")!)
        context.apply(to: &request, now: now)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "a=v")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "UA/1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com/watch?v=1")
    }

    func testApplyWithoutMatchingCookiesAddsNoCookieHeader() {
        let context = RequestContext(cookies: [cookie("b", domain: "other.com")], userAgent: nil, referer: nil)
        var request = URLRequest(url: URL(string: "https://example.com/v.mp4")!)
        context.apply(to: &request, now: now)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    }

    func testCrossHostRedirectStripsCookieButKeepsRefererAndUserAgent() {
        let context = RequestContext(cookies: [cookie("a", domain: ".example.com")], userAgent: "UA/1", referer: URL(string: "https://example.com/watch"))
        var original = URLRequest(url: URL(string: "https://cdn.example.com/v.mp4")!)
        context.apply(to: &original, now: now)
        var redirect = original
        redirect.url = URL(string: "https://storage.other.net/v.mp4")!
        let result = RequestContext.redirectedRequest(redirect, from: original, context: context, now: now)
        XCTAssertNil(result.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(result.value(forHTTPHeaderField: "Referer"), "https://example.com/watch")
        XCTAssertEqual(result.value(forHTTPHeaderField: "User-Agent"), "UA/1")
        XCTAssertEqual(result.url?.host, "storage.other.net")
    }

    func testCrossHostRedirectToSameSiteSubdomainStillStripsCookie() {
        let context = RequestContext(cookies: [cookie("a", domain: ".example.com")], userAgent: nil, referer: nil)
        var original = URLRequest(url: URL(string: "https://www.example.com/v.mp4")!)
        context.apply(to: &original, now: now)
        var redirect = original
        redirect.url = URL(string: "https://cdn.example.com/v.mp4")!
        XCTAssertNil(RequestContext.redirectedRequest(redirect, from: original, context: context, now: now).value(forHTTPHeaderField: "Cookie"))
    }

    func testCrossHostRedirectWithoutContextStripsCookieKeepsHeaders() {
        var original = URLRequest(url: URL(string: "https://a.com/v")!)
        original.setValue("x=1", forHTTPHeaderField: "Cookie")
        original.setValue("https://a.com/", forHTTPHeaderField: "Referer")
        var redirect = URLRequest(url: URL(string: "https://b.com/v")!)
        redirect.setValue("x=1", forHTTPHeaderField: "Cookie")
        let result = RequestContext.redirectedRequest(redirect, from: original, context: nil, now: now)
        XCTAssertNil(result.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(result.value(forHTTPHeaderField: "Referer"), "https://a.com/")
    }

    func testSameHostRedirectRefiltersCookiesForNewURL() {
        let context = RequestContext(cookies: [cookie("root", domain: "example.com"), cookie("a", domain: "example.com", path: "/a"),
                                               cookie("sec", domain: "example.com", secure: true)],
                                     userAgent: "UA", referer: nil)
        var original = URLRequest(url: URL(string: "https://example.com/a/v.mp4")!)
        context.apply(to: &original, now: now)
        XCTAssertEqual(original.value(forHTTPHeaderField: "Cookie")?.contains("a=v"), true)
        var redirect = original
        redirect.url = URL(string: "http://EXAMPLE.com/b/v.mp4")!
        let result = RequestContext.redirectedRequest(redirect, from: original, context: context, now: now)
        XCTAssertEqual(result.value(forHTTPHeaderField: "Cookie"), "root=v")
        XCTAssertEqual(result.value(forHTTPHeaderField: "User-Agent"), "UA")
    }
}
