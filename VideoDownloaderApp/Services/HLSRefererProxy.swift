import Foundation
import Network
import os

/// Serves one HLS asset on loopback, forwarding each request to its original URL
/// with the browser's scoped cookies, User-Agent and player Referer. AVFoundation's
/// background HLS API cannot attach an arbitrary Referer to its own HTTP requests.
/// This relay must remain alive while the download runs, so the UI asks the user
/// to keep the app open for these streams.
/// Its tables are guarded by `lock`, and the listener and its connections run on `queue`.
final class HLSRefererProxy: @unchecked Sendable {
    enum ProxyError: Error { case couldNotStart }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "HLSRefererProxy")
    private let lock = NSLock()
    private var routes: [UUID: URL] = [:]
    /// AVFoundation fetches each playlist more than once (HEAD, GET, each rendition).
    /// Reusing one route per URL keeps the table bounded and the rewritten bodies identical.
    private var routeIDs: [URL: UUID] = [:]
    private let context: RequestContext
    private let session: URLSession
    private var port: UInt16?

    init(context: RequestContext) throws {
        self.context = context
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    deinit { stop() }

    /// Waits (without blocking the caller's thread) up to 5 s for the loopback listener.
    func start(for original: URL) async throws -> URL {
        let succeeded: Bool = await withCheckedContinuation { continuation in
            // Exactly one of the handlers below resumes.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Bool) {
                guard !resumed.withLock({ resumed in defer { resumed = true }; return resumed }) else { return }
                continuation.resume(returning: result)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self else { return finish(false) }
                    self.lock.lock()
                    self.port = self.listener.port?.rawValue
                    let hasPort = self.port != nil
                    self.lock.unlock()
                    finish(hasPort)
                case .failed, .cancelled:
                    finish(false)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        guard succeeded else { throw ProxyError.couldNotStart }
        return localURL(for: original)
    }

    func stop() {
        listener.cancel()
        session.invalidateAndCancel()
    }

    private func localURL(for remote: URL) -> URL {
        lock.lock()
        let id = routeIDs[remote] ?? UUID()
        routeIDs[remote] = id
        routes[id] = remote
        let port = self.port
        lock.unlock()
        let suffix = remote.pathExtension.lowercased() == "m3u8" ? "m3u8" : "bin"
        return URL(string: "http://127.0.0.1:\(port ?? 0)/r/\(id.uuidString)/asset.\(suffix)")!
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, accumulated: Data())
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task { await self.respond(to: request, on: connection) }
            } else if ended || error != nil || request.count > 65_536 {
                connection.cancel()
            } else {
                self.read(connection, accumulated: request)
            }
        }
    }

    private func respond(to raw: Data, on connection: NWConnection) async {
        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, ["GET", "HEAD"].contains(parts[0]),
              let path = String(parts[1]).split(separator: "?").first,
              let identifier = path.split(separator: "/").dropFirst().first.flatMap({ UUID(uuidString: String($0)) }) else {
            send(status: 400, type: "text/plain", body: Data(), to: connection)
            return
        }
        let remote = lock.withLock { routes[identifier] }
        guard let remote else {
            send(status: 404, type: "text/plain", body: Data(), to: connection)
            return
        }
        let isHead = parts[0] == "HEAD"
        var request = URLRequest(url: remote)
        // Read the complete source even for HEAD so the rewritten playlist's
        // Content-Length matches the GET response AVFoundation will receive.
        request.httpMethod = "GET"
        context.apply(to: &request)
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            request.setValue(String(range.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
        }
        do {
            let delegate = RedirectScoper(context: context, original: request)
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request, delegate: delegate)
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                // One more go: a single dropped segment would otherwise fail the whole download.
                result = try await session.data(for: request, delegate: delegate)
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw ProxyError.couldNotStart }
            let finalURL = response.url ?? remote
            let type = http.mimeType ?? (finalURL.pathExtension.lowercased() == "m3u8" ? "application/vnd.apple.mpegurl" : "application/octet-stream")
            let isPlaylist = type.lowercased().contains("mpegurl") || finalURL.pathExtension.lowercased() == "m3u8" || data.starts(with: Data("#EXTM3U".utf8))
            let body: Data
            if (200..<300).contains(http.statusCode), isPlaylist, let text = String(data: data, encoding: .utf8) {
                body = Data(Self.rewritePlaylist(text, baseURL: finalURL) { self.localURL(for: $0) }.utf8)
            } else { body = data }
            send(status: http.statusCode, type: isPlaylist ? "application/vnd.apple.mpegurl" : type,
                 body: body, includeBody: !isHead, contentRange: http.value(forHTTPHeaderField: "Content-Range"), to: connection)
        } catch {
            send(status: 502, type: "text/plain", body: Data(), to: connection)
        }
    }

    private func send(status: Int, type: String, body: Data, includeBody: Bool = true,
                      contentRange: String? = nil, to connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccept-Ranges: bytes\r\n"
        if let contentRange { header += "Content-Range: \(contentRange)\r\n" }
        header += "\r\n"
        connection.send(content: Data(header.utf8) + (includeBody ? body : Data()), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Rebase variant, segment, map, key and subtitle URLs to this relay.
    static func rewritePlaylist(_ text: String, baseURL: URL, map: (URL) -> URL) -> String {
        let pattern = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("#") {
                let matches = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
                var rewritten = line
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: rewritten),
                          let remote = URL(string: String(rewritten[range]), relativeTo: baseURL)?.absoluteURL,
                          remote.isWeb else { continue }
                    rewritten.replaceSubrange(range, with: map(remote).absoluteString)
                }
                return rewritten
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let remote = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
                  remote.isWeb else { return line }
            return map(remote).absoluteString
        }.joined(separator: "\n")
    }
}
