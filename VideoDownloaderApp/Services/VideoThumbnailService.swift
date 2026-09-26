import AVFoundation
import CoreImage
import UIKit

/// Extracts a still from a saved video. HLS packages often have no I-frame-only
/// rendition, so AVAssetImageGenerator alone cannot provide their thumbnails.
@MainActor
enum VideoThumbnailService {
    private static let size = CGSize(width: 240, height: 160)
    private static let ciContext = CIContext()

    static func imageData(for url: URL, kind: MediaKind) async -> Data? {
        let asset = AVURLAsset(url: url)
        if kind != .hls, let image = await generatedImage(for: asset) {
            return jpegData(for: image)
        }
        if let image = await playbackImage(for: asset) {
            return jpegData(for: image)
        }
        return nil
    }

    private static func generatedImage(for asset: AVAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            if Task.isCancelled { return nil }
            if let result = try? await generator.image(at: time) { return result.image }
        }
        return nil
    }

    private static func playbackImage(for asset: AVAsset) async -> CGImage? {
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause(); item.remove(output) }

        // A player can decode regular HLS renditions even when image generation
        // cannot. Wait for a non-initial frame, then take the first available one.
        for _ in 0..<60 {
            if Task.isCancelled { return nil }
            let time = player.currentTime()
            if time.seconds >= 0.5,
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                return ciContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(
                    x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func jpegData(for frame: CGImage) -> Data? {
        let scale = min(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height), 1)
        let dimensions = CGSize(width: max(1, CGFloat(frame.width) * scale),
                                height: max(1, CGFloat(frame.height) * scale))
        return UIGraphicsImageRenderer(size: dimensions).jpegData(withCompressionQuality: 0.8) { context in
            UIImage(cgImage: frame).draw(in: CGRect(origin: .zero, size: dimensions))
        }
    }
}
