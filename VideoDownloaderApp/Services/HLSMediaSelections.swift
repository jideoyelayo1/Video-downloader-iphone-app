import AVFoundation

/// Keep the stream's default audio when requesting extra caption languages.
/// A preferred media selection can leave an optional AUDIO group empty; copying
/// that selection for every subtitle would save a playable but silent video.
enum HLSMediaSelections {
    static func audibleOption(for asset: AVURLAsset, preferred: AVMediaSelection) async -> (AVMediaSelectionGroup, AVMediaSelectionOption)? {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return nil }
        let cached = asset.assetCache?.mediaSelectionOptions(in: group)
        let available = cached?.isEmpty == false ? cached! : group.options
        let preferredOption = preferred.selectedMediaOption(in: group)
        let option = preferredOption.flatMap { choice in available.first(where: { $0 == choice }) }
            ?? group.defaultOption.flatMap { choice in available.first(where: { $0 == choice }) }
            ?? available.first
        guard let option else { return nil }
        return (group, option)
    }

    /// A saved HLS package can be playable while its separate audio rendition is absent.
    static func isOfflineAudioMissing(in asset: AVURLAsset) async -> Bool {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
              !group.options.isEmpty,
              let cache = asset.assetCache,
              cache.mediaSelectionOptions(in: group).isEmpty else { return false }
        let embeddedAudio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return embeddedAudio.isEmpty
    }

    static func forDownload(asset: AVURLAsset) async -> [AVMediaSelection] {
        guard let preferred = try? await asset.load(.preferredMediaSelection),
              let base = preferred.mutableCopy() as? AVMutableMediaSelection else { return [] }
        let audio = await audibleOption(for: asset, preferred: preferred)
        if let (group, option) = audio { base.select(option, in: group) }

        guard let captions = try? await asset.loadMediaSelectionGroup(for: .legible),
              !captions.options.isEmpty else { return audio == nil ? [] : [base] }
        return captions.options.compactMap { caption in
            guard let selection = base.mutableCopy() as? AVMutableMediaSelection else { return nil }
            selection.select(caption, in: captions)
            return selection
        }
    }
}
