import Foundation
import Network
import os

/// Serves one saved video, with its poster and subtitle files, to a Chromecast on the same Wi-Fi:
/// the Chromecast fetches what it plays by URL, so the phone has to be its web server.
/// Only the files in a fixed table under a random token can be fetched, and only by the listed
/// peers (the Chromecast and the phone itself).
/// The table never changes after `init`; connections, refused peers, `stopped` and the file
/// handle are only touched on `queue`.
final class CastMediaServer: @unchecked Sendable {
    enum ServerError: Error { case couldNotStart }

    struct Extra {
        let type: String
        let data: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "CastMediaServer")
    private let token = UUID().uuidString
    private let host: String
    private let allowedPeers: [IPv4Address]
    /// Kept open for the whole cast, so a video deleted or replaced meanwhile still plays to the end.
    private let video: FileHandle
    private let videoLength: Int
    private let extras: [String: Extra]
    private let refused: @Sendable (String) -> Void
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var refusedPeers: Set<String> = []
    private var stopped = false
    /// Videos run to several GB, so they go out one chunk at a time.
    private static let chunkSize = 512 * 1024

    /// - Parameters:
    ///   - host: the phone's address on the Chromecast's network (`lanAddress(near:)`).
    ///   - extras: small files by name, such as `"poster.jpg"` or `"subtitles/0.vtt"`.
    ///   - refused: told the address of each connection turned away.
    init(host: String, allowedPeers: [IPv4Address], video: URL, extras: [String: Extra],
         refused: @escaping @Sendable (String) -> Void) throws {
        self.host = host
        self.allowedPeers = allowedPeers
        self.video = try FileHandle(forReadingFrom: video)
        videoLength = Int(try self.video.seekToEnd())
        self.extras = extras
        self.refused = refused
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit { listener.cancel() }

    /// Waits (without blocking the caller's thread) up to 5 s for the listener.
    /// - Returns: the folder URL the files are served under, ending in `/`.
    func start() async throws -> URL {
        let succeeded: Bool = await withCheckedContinuation { continuation in
            // Exactly one of the handlers below resumes.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Bool) {
                guard !resumed.withLock({ resumed in defer { resumed = true }; return resumed }) else { return }
                continuation.resume(returning: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        guard succeeded, let port = listener.port?.rawValue else { throw ServerError.couldNotStart }
        return URL(string: "http://\(host):\(port)/\(token)/")!
    }

    func stop() {
        listener.cancel()
        queue.sync {
            stopped = true
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            try? video.close()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, case .hostPort(let peerHost, _) = connection.endpoint else { return connection.cancel() }
        let peer: IPv4Address? = switch peerHost {
        case .ipv4(let address): address
        case .ipv6(let address): address.asIPv4
        default: nil
        }
        guard let peer, allowedPeers.contains(where: { $0.rawValue == peer.rawValue }) else {
            // Once per address, so one that keeps retrying can't fill the error log.
            if refusedPeers.insert("\(peerHost)").inserted { refused("\(peerHost)") }
            return connection.cancel()
        }
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer[..<end.lowerBound], on: connection)
            } else if ended || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return send(status: 400, on: connection) }
        let method = parts[0]
        guard ["GET", "HEAD", "OPTIONS"].contains(method) else { return send(status: 405, on: connection) }
        // An exact match in the table: nothing in the path is ever turned into a file path.
        let path = parts[1].prefix { $0 != "?" }
        let prefix = "/\(token)/"
        let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        let extra = extras[name]
        guard name == "video.mp4" || extra != nil else { return send(status: 404, on: connection) }
        // The receiver's page is HTTPS on another origin, so its browser may ask first.
        guard method != "OPTIONS" else {
            return send(status: 204, on: connection, headers: ["Access-Control-Allow-Methods: GET, HEAD",
                                                              "Access-Control-Allow-Headers: Range",
                                                              "Access-Control-Allow-Private-Network: true"])
        }
        let length = extra?.data.count ?? videoLength
        var range = 0..<length
        var status = 200
        if let header = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            guard let requested = Self.byteRange(String(header.dropFirst("range:".count)), length: length) else {
                return send(status: 416, on: connection, headers: ["Content-Range: bytes */\(length)"])
            }
            range = requested
            status = 206
        }
        var headers = ["Content-Type: \(extra?.type ?? "video/mp4")", "Content-Length: \(range.count)"]
        if status == 206 { headers.append("Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)") }
        let header = Self.header(status: status, headers + ["Accept-Ranges: bytes"])
        if method == "HEAD" { return finish(header, on: connection) }
        if let extra { return finish(header + extra.data[range], on: connection) }
        connection.send(content: header, completion: .contentProcessed { [weak self, range] error in
            guard error == nil, let self else { return connection.cancel() }
            self.stream(range, on: connection)
        })
    }

    /// Reads each chunk only once the last has gone, so memory stays at one chunk per connection.
    private func stream(_ range: Range<Int>, on connection: NWConnection) {
        guard !stopped else { return connection.cancel() }
        guard !range.isEmpty else { return finish(Data(), on: connection) }
        let chunk: Data
        do {
            try video.seek(toOffset: UInt64(range.lowerBound))
            chunk = try video.read(upToCount: min(Self.chunkSize, range.count)) ?? Data()
        } catch { return connection.cancel() }
        guard !chunk.isEmpty else { return connection.cancel() }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return connection.cancel() }
            self.stream(range.dropFirst(chunk.count), on: connection)
        })
    }

    private func send(status: Int, on connection: NWConnection, headers: [String] = []) {
        finish(Self.header(status: status, headers + ["Content-Length: 0"]), on: connection)
    }

    private func finish(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func header(status: Int, _ headers: [String]) -> Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        // Subtitles are fetched by the receiver's page, which needs CORS.
        let common = ["Access-Control-Allow-Origin: *", "Cache-Control: no-store", "Connection: close"]
        return Data(("HTTP/1.1 \(status) \(reason)\r\n" + (headers + common).map { $0 + "\r\n" }.joined() + "\r\n").utf8)
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

    /// The phone's IPv4 address on the same subnet as `device`: Wi-Fi, or the phone's own
    /// Personal Hotspot, and never a VPN's.
    static func lanAddress(near device: String) -> String? {
        guard let target = IPv4Address(device)?.rawValue.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard netmask != 0, local & netmask == target & netmask else { continue }
            return IPv4Address(withUnsafeBytes(of: local) { Data($0) }).map { "\($0)" }
        }
        return nil
    }

    /// Saved subtitle files can hold SRT text; the Chromecast reads only WebVTT.
    static func webVTT(_ text: String) -> String {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard !body.hasPrefix("WEBVTT") else { return body }
        let timestamps = try! NSRegularExpression(pattern: #"(\d{2}:\d{2}:\d{2}),(\d{3})"#)
        return "WEBVTT\n\n" + timestamps.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "$1.$2")
    }
}
