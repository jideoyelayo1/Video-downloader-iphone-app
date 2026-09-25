import Foundation

@main
struct PortableMediaDiscoveryTests {
    static func main() {
        let page = URL(string: "https://example.com/watch")!
        precondition(MediaDiscovery.candidate(from: ["url": "blob:https://example.com/1"], sourcePageURL: page) == nil)
        precondition(MediaDiscovery.candidate(from: ["url": "https://example.com/site.js"], sourcePageURL: page) == nil)
        let hls = MediaDiscovery.candidate(from: ["url": "https://cdn.example/episode.m3u8?token=1"], sourcePageURL: page)
        precondition(hls?.kind == .hls)
        let direct = MediaDiscovery.candidate(from: ["url": "https://cdn.example/stream?id=1", "kind": "unknown", "mediaElement": true], sourcePageURL: page)
        precondition(direct?.kind == .unknown)
        let a = MediaCandidate(url: URL(string: "https://cdn.example/video.mp4#one")!, sourcePageURL: page)
        let b = MediaCandidate(url: URL(string: "https://cdn.example/video.mp4#two")!, sourcePageURL: page)
        precondition(MediaDiscovery.isDuplicate(b, in: [a]))
        precondition(DownloadResponseValidation.failureMessage(statusCode: 200, mimeType: "video/mp4") == nil)
        precondition(DownloadResponseValidation.failureMessage(statusCode: 200, mimeType: "application/vnd.apple.mpegurl") != nil)
        precondition(DownloadResponseValidation.failureMessage(statusCode: 200, mimeType: "text/html") != nil)
        precondition(DownloadResponseValidation.failureMessage(statusCode: 200, mimeType: "application/octet-stream", prefixData: Data("#EXTM3U\n".utf8)) != nil)
        precondition(DownloadResponseValidation.failureMessage(statusCode: 503, mimeType: "video/mp4") != nil)
        precondition(DownloadResponseValidation.failure(statusCode: 403, mimeType: "video/mp4") == .expiredLink)
        precondition(DownloadResponseValidation.failureMessage(statusCode: 403, mimeType: nil) == DownloadError.expiredLink.message)
        print("Swift MediaDiscoveryCore checks passed")
    }
}
