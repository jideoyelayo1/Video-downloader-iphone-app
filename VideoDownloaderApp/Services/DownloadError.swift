import Foundation

enum DownloadError: Error, Equatable {
    case expiredLink
    case notFound
    case httpStatus(Int)
    case notVideo
    case streamSegment
    case hlsPlaylistAsFile
    case protectedStream
    case liveStream
    case insufficientStorage(required: Int64?, available: Int64?)
    case offline
    case networkLost
    case timedOut
    case cancelled
    case other(String)

    static let storageSafetyMargin: Int64 = 200 * 1024 * 1024

    var message: String {
        switch self {
        case .expiredLink: return "The link expired. Replay the video in Browse and download again."
        case .notFound: return "The video is no longer available at this link. Replay it in Browse and try again."
        case .httpStatus(let code): return "The server returned HTTP status \(code). Try again later."
        case .notVideo: return "The server returned a non-video response. Play the video in Browse and pick another source."
        case .streamSegment: return "This file is one piece of a stream, not the whole video. Choose its playlist instead."
        case .hlsPlaylistAsFile: return "The URL is an HLS playlist; choose its manifest as an HLS download."
        case .protectedStream: return "This video is DRM-protected and can't be downloaded."
        case .liveStream: return "Live streams can't be downloaded. Try again once the broadcast has ended."
        case .insufficientStorage(let required, let available):
            if let required, let available, required > available {
                let needed = ByteCountFormatter.string(fromByteCount: required - available, countStyle: .file)
                return "Not enough storage. Free up \(needed) and try again."
            }
            return "Not enough storage. Free up some space and try again."
        case .offline: return "You're offline. Connect to the internet and try again."
        case .networkLost: return "The network connection was lost. Try again."
        case .timedOut: return "The server took too long to respond. Try again."
        case .cancelled: return "The download was cancelled."
        case .other(let description): return description
        }
    }

    static func from(statusCode: Int) -> DownloadError? {
        switch statusCode {
        case 200..<300: return nil
        case 401, 403, 410: return .expiredLink
        case 404: return .notFound
        default: return .httpStatus(statusCode)
        }
    }

    static func from(_ error: Error) -> DownloadError {
        if let error = error as? DownloadError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed: return .offline
            case .networkConnectionLost: return .networkLost
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            case .cannotWriteToFile: return .insufficientStorage(required: nil, available: nil)
            default: break
            }
        }
        let nsError = error as NSError
        if nsError.domain == "CoreMediaErrorDomain", nsError.code == -16847,
           nsError.localizedDescription.contains("HTTP 500") {
            return .other("The video server returned HTTP 500 during download. Replay the episode in Browse to get a fresh link, then download it again.")
        }
        if isOutOfSpace(nsError) { return .insufficientStorage(required: nil, available: nil) }
        return .other(error.localizedDescription)
    }

    /// Nil if `availableBytes` covers `expectedBytes` plus a 200 MB safety margin. Unknown availability passes.
    static func storageCheck(expectedBytes: Int64?, availableBytes: Int64?) -> DownloadError? {
        guard let availableBytes else { return nil }
        let expected = max(expectedBytes ?? 0, 0)
        let required = expected + storageSafetyMargin
        guard availableBytes < required else { return nil }
        return .insufficientStorage(required: required, available: availableBytes)
    }

    private static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }
}
