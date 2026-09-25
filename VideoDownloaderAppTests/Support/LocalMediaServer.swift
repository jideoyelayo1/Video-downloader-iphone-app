import Foundation
import Network

/// A tiny HTTP/1.1 server on 127.0.0.1 (ephemeral port) serving fixture media for integration and UI tests.
///
/// Every response carries `Content-Length` and `Connection: close`. GET and HEAD are supported; other methods get 405.
/// Routes marked (Range) honour `Range: bytes=a-b`, `bytes=a-` and `bytes=-n` with 206 + `Content-Range` (416 if unsatisfiable).
///
/// - `/video.mp4` — MP4 fixture, video/mp4 (Range).
/// - `/noext/stream?id=1` — same MP4 bytes with no extension, video/mp4 (Range).
/// - `/hls/master.m3u8` — master playlist, two variants (500 kbps 320x180, 900 kbps 640x360) both pointing at `media.m3u8`.
/// - `/hls/media.m3u8` — finite VOD media playlist (`#EXT-X-ENDLIST`); segments served at `/hls/<segment name>` (Range).
/// - `/hls/live.m3u8` — the same media playlist without `#EXT-X-ENDLIST` / `#EXT-X-PLAYLIST-TYPE`.
/// - `/hls/drm.m3u8` — the media playlist with `#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key"`.
/// - `/cookie/video.mp4` — MP4 only if the Cookie header contains `session=ok`, else 403 (Range).
/// - `/referer/video.mp4` — MP4 only if Referer starts with `<baseURL>page`, else 403 (Range).
/// - `/redirect/video.mp4` — 302 to `/video.mp4`.
/// - `/redirect-cross/video.mp4` — 302 to `http://localhost:<port>/echo-cookie` (same server, different host string).
/// - `/echo-cookie` — 200 text/plain; body is the received Cookie header (empty if none).
/// - `/expired/video.mp4` — 410.
/// - `/missing.mp4` — 404.
/// - `/html/video.mp4` — 200 text/html fake error page.
/// - `/drop/video.mp4` — full Content-Length header, then about half the body, then the connection closes (Range).
/// - `/slow/video.mp4` — MP4 streamed in ~24 chunks, 100 ms apart (~2.4 s total) (Range).
/// - `/page/basic.html` — `<video src="/video.mp4" controls>`.
/// - `/page/dynamic.html` — inserts `<video src="/noext/stream?id=1">` via JS after 500 ms.
/// - `/page/iframe.html` — `<iframe src="/page/basic.html">`.
/// - `/page/hls.html` — `<video src="/hls/master.m3u8">`.
/// - `/page/links.html` — index linking to every page above.
/// - anything else — 404.
final class LocalMediaServer {
    struct RecordedRequest {
        let method: String
        let path: String
        let query: String?
        /// Header names are lowercased; use `header(_:)` for case-insensitive lookup.
        let headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var queryItems: [URLQueryItem] { URLComponents(string: "?" + (query ?? ""))?.queryItems ?? [] }
    }

    enum ServerError: Error { case notStarted, listenerFailed(Error?), missingFixture(String) }

    let fixtures: FixtureSet
    private(set) var baseURL: URL?
    var port: UInt16? { baseURL?.port.map(UInt16.init) }

    var requests: [RecordedRequest] { lock.withLock { recorded } }
    func clearRequests() { lock.withLock { recorded.removeAll() } }
    func requests(to path: String) -> [RecordedRequest] { requests.filter { $0.path == path } }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalMediaServer")
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(fixtures: FixtureSet) throws {
        self.fixtures = fixtures
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        queue.setSpecific(key: queueKey, value: ())
    }

    convenience init() throws { try self.init(fixtures: .bundled()) }

    deinit { stop() }

    /// Starts listening and returns the base URL `http://127.0.0.1:<port>/`.
    @discardableResult
    func start() throws -> URL {
        if let baseURL { return baseURL }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure == nil, let port = listener.port?.rawValue else {
            listener.cancel()
            throw ServerError.listenerFailed(failure)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        baseURL = url
        return url
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let cancelAll = {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
        DispatchQueue.getSpecific(key: queueKey) == nil ? queue.sync(execute: cancelAll) : cancelAll()
    }

    /// Absolute URL for a route path such as `"/video.mp4"` or `"noext/stream?id=1"`.
    func url(_ path: String) -> URL {
        guard let baseURL else { fatalError("LocalMediaServer.url(_:) called before start()") }
        return URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: baseURL)!.absoluteURL
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(head: buffer[..<end.lowerBound], on: connection)
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard parts.count >= 2 else { return send(Response(status: 400), for: nil, on: connection) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let target = String(parts[1])
        let pathEnd = target.firstIndex(of: "?") ?? target.endIndex
        let request = RecordedRequest(
            method: String(parts[0]).uppercased(),
            path: String(target[..<pathEnd]).removingPercentEncoding ?? String(target[..<pathEnd]),
            query: pathEnd < target.endIndex ? String(target[target.index(after: pathEnd)...]) : nil,
            headers: headers)
        lock.withLock { recorded.append(request) }
        let response = request.method == "GET" || request.method == "HEAD" ? route(request) : Response(status: 405)
        send(response, for: request, on: connection)
    }

    // MARK: - Routing

    private struct Response {
        enum Delivery { case normal, drop, slow }
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var rangeable = false
        var delivery = Delivery.normal

        static func data(_ body: Data, _ type: String, rangeable: Bool = true, delivery: Delivery = .normal) -> Response {
            Response(status: 200, headers: ["Content-Type": type], body: body, rangeable: rangeable, delivery: delivery)
        }
        static func text(_ text: String, _ type: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": type], body: Data(text.utf8))
        }
        static func redirect(_ location: String) -> Response {
            Response(status: 302, headers: ["Location": location])
        }
    }

    private func route(_ request: RecordedRequest) -> Response {
        let mp4 = Response.data(fixtures.mp4, "video/mp4")
        let origin = baseURL?.absoluteString ?? ""
        switch request.path {
        case "/video.mp4", "/noext/stream": return mp4
        case "/hls/master.m3u8": return .text(masterPlaylist, Self.hlsType)
        case "/hls/media.m3u8": return .text(fixtures.hlsMediaPlaylist, Self.hlsType)
        case "/hls/live.m3u8": return .text(livePlaylist, Self.hlsType)
        case "/hls/drm.m3u8": return .text(drmPlaylist, Self.hlsType)
        case "/hls/html-segment.m3u8": return .text("#EXTM3U\n#EXTINF:4,\nhtml-segment.ts\n#EXT-X-ENDLIST\n", Self.hlsType)
        case "/hls/html-segment.ts": return .text("<!doctype html><html><body>challenge</body></html>", "text/html; charset=utf-8")
        case "/hls/nested-playlist-segment.m3u8": return .text("#EXTM3U\n#EXTINF:4,\nnested-playlist-segment.ts\n#EXT-X-ENDLIST\n", Self.hlsType)
        case "/hls/nested-playlist-segment.ts": return .text("#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n", Self.hlsType)
        case "/cookie/video.mp4":
            return request.header("cookie")?.contains("session=ok") == true ? mp4 : .text("Forbidden", "text/plain", status: 403)
        case "/referer/video.mp4":
            return request.header("referer")?.hasPrefix(origin + "page") == true ? mp4 : .text("Forbidden", "text/plain", status: 403)
        case "/redirect/video.mp4": return .redirect(origin + "video.mp4")
        case "/redirect-cross/video.mp4": return .redirect("http://localhost:\(port ?? 0)/echo-cookie")
        case "/echo-cookie": return .text(request.header("cookie") ?? "", "text/plain")
        case "/expired/video.mp4": return .text("Gone", "text/plain", status: 410)
        case "/html/video.mp4":
            return .text("<!doctype html><html><head><title>Error</title></head><body><h1>Access denied</h1></body></html>", "text/html; charset=utf-8")
        case "/drop/video.mp4": return .data(fixtures.mp4, "video/mp4", delivery: .drop)
        case "/slow/video.mp4": return .data(fixtures.mp4, "video/mp4", delivery: .slow)
        default:
            if request.path.hasPrefix("/page/"), let html = Self.pages[String(request.path.dropFirst(6))] {
                return .text(html, "text/html; charset=utf-8")
            }
            if request.path.hasPrefix("/hls/"), let segment = fixtures.hlsSegments[String(request.path.dropFirst(5))] {
                return .data(segment, Self.contentType(forExtension: (request.path as NSString).pathExtension))
            }
            return .text("Not Found", "text/plain", status: 404)
        }
    }

    private static let reasons = [200: "OK", 206: "Partial Content", 302: "Found", 400: "Bad Request", 403: "Forbidden",
                                  404: "Not Found", 405: "Method Not Allowed", 410: "Gone", 416: "Range Not Satisfiable"]

    static let hlsType = "application/vnd.apple.mpegurl"

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "m3u8": return hlsType
        case "ts": return "video/mp2t"
        case "m4s": return "video/iso.segment"
        case "html", "htm": return "text/html; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private var masterPlaylist: String {
        """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180,CODECS="avc1.42c01e,mp4a.40.2"
        media.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
        media.m3u8

        """
    }

    private var livePlaylist: String {
        fixtures.hlsMediaPlaylist.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#EXT-X-ENDLIST") && !$0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }
            .joined(separator: "\n")
    }

    private var drmPlaylist: String {
        var lines = fixtures.hlsMediaPlaylist.components(separatedBy: "\n")
        let index = lines.firstIndex { $0.hasPrefix("#EXTINF") } ?? lines.count
        lines.insert(#"#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1""#, at: index)
        return lines.joined(separator: "\n")
    }

    private static func page(_ title: String, _ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(title)</title></head>
        <body><h1>\(title)</h1>
        \(body)
        </body></html>
        """
    }

    static let pages: [String: String] = [
        "basic.html": page("Basic Video Page", #"<video id="video" src="/video.mp4" controls playsinline width="320" height="180"></video>"#),
        "dynamic.html": page("Dynamic Video Page", """
            <div id="holder"></div>
            <script>
            setTimeout(function () {
              var v = document.createElement('video');
              v.id = 'video'; v.src = '/noext/stream?id=1'; v.controls = true; v.setAttribute('playsinline', '');
              document.getElementById('holder').appendChild(v);
            }, 500);
            </script>
            """),
        "iframe.html": page("Iframe Video Page", #"<iframe id="frame" src="/page/basic.html" width="360" height="260"></iframe>"#),
        "hls.html": page("HLS Video Page", #"<video id="video" src="/hls/master.m3u8" controls playsinline width="320" height="180"></video>"#),
        "links.html": page("Test Links", """
            <ul>
            <li><a id="basic" href="/page/basic.html">Basic video</a></li>
            <li><a id="dynamic" href="/page/dynamic.html">Dynamic video</a></li>
            <li><a id="iframe" href="/page/iframe.html">Iframe video</a></li>
            <li><a id="hls" href="/page/hls.html">HLS video</a></li>
            </ul>
            """),
    ]

    // MARK: - Sending

    private func send(_ response: Response, for request: RecordedRequest?, on connection: NWConnection) {
        var response = response
        var body = response.body
        if response.rangeable, response.status == 200 {
            response.headers["Accept-Ranges"] = "bytes"
            if let spec = request?.header("range") {
                if let range = Self.byteRange(spec, length: body.count) {
                    response.status = 206
                    response.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)"
                    body = body.subdata(in: range)
                } else {
                    response.headers["Content-Range"] = "bytes */\(body.count)"
                    response = Response(status: 416, headers: response.headers)
                    body = Data()
                }
            }
        }
        var head = "HTTP/1.1 \(response.status) \(Self.reasons[response.status] ?? "Status")\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        if request?.method == "HEAD" { body = Data() }
        switch response.delivery {
        case .normal:
            finish(Data(head.utf8) + body, on: connection)
        case .drop:
            let partial = body.prefix(body.count / 2)
            connection.send(content: Data(head.utf8) + partial, completion: .contentProcessed { _ in connection.cancel() })
        case .slow:
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil else { return connection.cancel() }
                self?.trickle(body, chunk: max(1, body.count / 24 + 1), on: connection)
            })
        }
    }

    private func trickle(_ remaining: Data, chunk: Int, on connection: NWConnection) {
        guard !remaining.isEmpty else { return finish(Data(), on: connection) }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard connection.state == .ready else { return connection.cancel() }
            connection.send(content: remaining.prefix(chunk), completion: .contentProcessed { error in
                guard error == nil else { return connection.cancel() }
                self?.trickle(remaining.dropFirst(chunk), chunk: chunk, on: connection)
            })
        }
    }

    private func finish(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Parses a single `bytes=` range; nil when unsatisfiable or malformed.
    static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes="), length > 0 else { return nil }
        guard let first = spec.dropFirst(6).split(separator: ",").first else { return nil }
        let bounds = first.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(bounds[0]), start < length else { return nil }
        let end = bounds[1].isEmpty ? length - 1 : min(Int(bounds[1]) ?? -1, length - 1)
        return end >= start ? start..<(end + 1) : nil
    }
}

/// Fixture bytes served by `LocalMediaServer`.
struct FixtureSet {
    var mp4: Data
    /// Media playlist text; segment URIs are bare file names resolved against `/hls/`.
    var hlsMediaPlaylist: String
    var hlsSegments: [String: Data]

    /// Loads `fixture.mp4`, `fixture_media.m3u8` and its segments from the bundle containing `LocalMediaServer`.
    static func bundled(in bundle: Bundle = Bundle(for: LocalMediaServer.self)) throws -> FixtureSet {
        let playlist = String(decoding: try load("fixture_media.m3u8", in: bundle), as: UTF8.self)
        var segments: [String: Data] = [:]
        for line in playlist.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") {
            segments[line] = try load(line, in: bundle)
        }
        return FixtureSet(mp4: try load("fixture.mp4", in: bundle), hlsMediaPlaylist: playlist, hlsSegments: segments)
    }

    /// Finds a resource by file name whether the bundle flattened `Fixtures/` or kept it as a folder.
    static func resourceURL(named name: String, in bundle: Bundle) -> URL? {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for subdirectory in [nil, "Fixtures", "Support/Fixtures"] {
            if let url = bundle.url(forResource: base, withExtension: ext, subdirectory: subdirectory) { return url }
        }
        guard let root = bundle.resourceURL,
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        return files.lazy.compactMap { $0 as? URL }.first { $0.lastPathComponent == name }
    }

    /// `.ts` files are stored as `<name>.bin` because Xcode treats `.ts` as TypeScript and won't copy it as a resource.
    private static func load(_ name: String, in bundle: Bundle) throws -> Data {
        guard let url = resourceURL(named: name, in: bundle) ?? resourceURL(named: name + ".bin", in: bundle) else { throw LocalMediaServer.ServerError.missingFixture(name) }
        return try Data(contentsOf: url)
    }
}
