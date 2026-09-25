import Foundation

enum DownloadResponseValidation {
    static func failure(statusCode: Int, mimeType: String?, prefixData: Data? = nil) -> DownloadError? {
        if let error = DownloadError.from(statusCode: statusCode) { return error }
        let mime = mimeType?.lowercased() ?? ""
        if mime.contains("mpegurl") { return .hlsPlaylistAsFile }
        let prefix = String(data: prefixData ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if prefix.hasPrefix("#extm3u") { return .hlsPlaylistAsFile }
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") || prefix.hasPrefix("<script") || mime.contains("text/html") || mime.contains("javascript") || mime.contains("json") { return .notVideo }
        if !mime.isEmpty && !(mime.hasPrefix("video/") || mime == "application/octet-stream" || mime == "binary/octet-stream" || mime.contains("mp4")) { return .notVideo }
        return nil
    }

    static func failureMessage(statusCode: Int, mimeType: String?, prefixData: Data? = nil) -> String? {
        failure(statusCode: statusCode, mimeType: mimeType, prefixData: prefixData)?.message
    }
}
