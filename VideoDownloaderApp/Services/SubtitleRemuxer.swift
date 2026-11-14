import AVFoundation
import CoreMedia

/// Real subtitle tracks, copied in without re-encoding, reach Picture in Picture and AirPlay; the overlay can't.
enum SubtitleRemuxer {
    struct Track {
        let language: String?
        let name: String
        let cues: [SubtitleCue]
    }

    enum Failure: Error {
        case nothingToCopy
        case cannotStart(String)
        case writeFailed(String)
    }

    static func remux(_ source: URL, adding tracks: [Track], defaultTrack: Int?, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let mediaTracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
        guard !mediaTracks.isEmpty else { throw Failure.nothingToCopy }
        let duration = try await asset.load(.duration)
        try? FileManager.default.removeItem(at: output)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var copies: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in mediaTracks {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { continue }
            reader.add(readerOutput)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            if let language = try? await track.load(.languageCode) { input.languageCode = language }
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            copies.append((readerOutput, input))
        }

        let format = try textFormatDescription()
        var texts: [(AVAssetWriterInput, [CMSampleBuffer])] = []
        for track in tracks {
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if let language = track.language {
                input.extendedLanguageTag = language
                if let code = Locale.Language(identifier: language).languageCode?.identifier(.alpha3) { input.languageCode = code }
            }
            // iOS names a track by its language; a title is only needed without one.
            if track.language == nil {
                let title = AVMutableMetadataItem()
                title.identifier = .quickTimeUserDataTrackName
                title.value = track.name as NSString
                input.metadata = [title]
            }
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            texts.append((input, try samples(for: track.cues, until: duration.seconds, format: format)))
        }
        // One selection group, so the languages appear together in the player's subtitle menu.
        if !texts.isEmpty {
            let inputs = texts.map(\.0)
            let group = AVAssetWriterInputGroup(inputs: inputs, defaultInput: defaultTrack.flatMap { inputs.indices.contains($0) ? inputs[$0] : nil })
            if writer.canAdd(group) { writer.add(group) }
        }

        guard reader.startReading() else { throw Failure.cannotStart(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw Failure.cannotStart(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "SubtitleRemuxer")
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (readerOutput, input) in copies {
                group.enter()
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard let sample = readerOutput.copyNextSampleBuffer(), input.append(sample) else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
            for (input, samples) in texts {
                group.enter()
                var next = 0
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard next < samples.count, input.append(samples[next]) else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        next += 1
                    }
                }
            }
            group.notify(queue: queue) { finished.resume() }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure.writeFailed(reader.error?.localizedDescription ?? "reading failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writeFailed(writer.error?.localizedDescription ?? "writing failed") }
    }

    /// Empty samples fill the gaps between cues so each line clears when it should.
    static func samples(for cues: [SubtitleCue], until end: Double, format: CMFormatDescription) throws -> [CMSampleBuffer] {
        var buffers: [CMSampleBuffer] = []
        var time = 0.0
        // Cues past the video's end would lengthen the movie, so they're clipped to it.
        for cue in cues.sorted(by: { $0.start < $1.start }) where cue.start >= time && cue.start < end {
            let cueEnd = min(cue.end, end)
            guard cueEnd > cue.start else { continue }
            if cue.start > time { buffers.append(try sample("", from: time, to: cue.start, format: format)) }
            buffers.append(try sample(cue.text, from: cue.start, to: cueEnd, format: format))
            time = cueEnd
        }
        if end > time { buffers.append(try sample("", from: time, to: end, format: format)) }
        return buffers
    }

    private static func sample(_ text: String, from start: Double, to end: Double, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8)
        var bytes = [UInt8(utf8.count >> 8 & 0xFF), UInt8(utf8.count & 0xFF)] + utf8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.writeFailed("block \(status)") }
        status = CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        guard status == noErr else { throw Failure.writeFailed("bytes \(status)") }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: end - start, preferredTimescale: 1000),
                                        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1000), decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                           sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Failure.writeFailed("sample \(status)") }
        return sample
    }

    /// White text, centred at the bottom, for subtitles iOS draws itself.
    private static func textFormatDescription() throws -> CMFormatDescription {
        let white: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                                      kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255]
        let clear: [CFString: Any] = [kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                                      kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 0]
        let box: [CFString: Any] = [kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                                    kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0]
        let style: [CFString: Any] = [kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                                      kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                                      kCMTextFormatDescriptionStyle_ForegroundColor: white, kCMTextFormatDescriptionStyle_FontSize: 18]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: clear,
            kCMTextFormatDescriptionExtension_DefaultTextBox: box,
            kCMTextFormatDescriptionExtension_DefaultStyle: style,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Helvetica"]
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle,
                                               mediaSubType: kCMTextFormatType_3GText, extensions: extensions as CFDictionary,
                                               formatDescriptionOut: &format)
        guard status == noErr, let format else { throw Failure.writeFailed("format \(status)") }
        return format
    }
}
