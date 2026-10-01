import Foundation

enum DownloadResponseValidation {
    static func failure(statusCode: Int, mimeType: String?, prefixData: Data? = nil) -> DownloadError? {
        if let error = DownloadError.from(statusCode: statusCode) { return error }
        let mime = mimeType?.lowercased() ?? ""
        if mime.contains("mpegurl") { return .hlsPlaylistAsFile }
        let prefix = String(data: prefixData ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if prefix.hasPrefix("#extm3u") { return .hlsPlaylistAsFile }
        if isDASH(mime: mime, prefix: prefix) { return .dashStream }
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") || prefix.hasPrefix("<script") || mime.contains("text/html") || mime.contains("javascript") || mime.contains("json") { return .notVideo }
        if !mime.isEmpty && !(mime.hasPrefix("video/") || mime == "application/octet-stream" || mime == "binary/octet-stream" || mime.contains("mp4")) { return .notVideo }
        return nil
    }

    /// Why a successful response to a playlist request isn't a usable HLS playlist.
    static func playlistFailure(mimeType: String?, data: Data) -> DownloadError {
        let mime = mimeType?.lowercased() ?? ""
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isDASH(mime: mime, prefix: prefix) { return .dashStream }
        // Labelled as a playlist but unreadable: an encoded body only the site's player understands.
        if mime.contains("mpegurl") && !data.isEmpty && !prefix.hasPrefix("<") && !prefix.hasPrefix("{") { return .scrambledStream }
        return .notVideo
    }

    private static func isDASH(mime: String, prefix: String) -> Bool {
        mime.contains("dash+xml") || prefix.hasPrefix("<mpd") || (prefix.hasPrefix("<?xml") && prefix.contains("<mpd"))
    }

    static func failureMessage(statusCode: Int, mimeType: String?, prefixData: Data? = nil) -> String? {
        failure(statusCode: statusCode, mimeType: mimeType, prefixData: prefixData)?.message
    }
}
