import AVFoundation
@preconcurrency import GoogleCast
import Network
import SwiftData
import UIKit

/// The Chromecast fetches files from the phone (`CastMediaServer`); saved HLS can't be served yet.
@MainActor
final class CastController: NSObject, @preconcurrency GCKSessionManagerListener, @preconcurrency GCKRemoteMediaClientListener,
                            @preconcurrency GCKRequestDelegate, @preconcurrency GCKUICastButtonDelegate {
    enum Failure: Error {
        case missingFile, notOnSameNetwork, couldNotServe

        var message: String {
            switch self {
            case .missingFile: "The saved video file is missing. Delete it and download the video again."
            case .notOnSameNetwork: "The iPhone and the Chromecast need to be on the same Wi-Fi."
            case .couldNotServe: "The video couldn't be sent to the Chromecast. Try again."
            }
        }
    }

    static let hlsMessage = "HLS videos can only go to the TV with AirPlay for now. Tap AirPlay in the player's controls."
    static let formatMessage = "The Chromecast couldn't play this video. Its format may not be one the Chromecast supports."

    weak var playback: PlaybackCoordinator?
    private let context: ModelContext
    private let diagnostics: DiagnosticsLog
    private(set) var castItem: DownloadItem?
    private var server: CastMediaServer?
    private var loadRequest: GCKRequest?
    /// Status updates before the current video has loaded belong to the one it replaced.
    private var mediaLoaded = false
    private var progressTimer: Timer?
    private var keepAlive: AVAudioPlayer?
    private var playID = UUID()
    private var audioObservers: [NSObjectProtocol] = []

    var isConnected: Bool { GCKCastContext.sharedInstance().sessionManager.hasConnectedCastSession() }
    var isServing: Bool { castItem != nil }
    private var client: GCKRemoteMediaClient? { GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient }

    /// Google asks for this at launch, so a cast still running can be picked up again.
    static func setUp(_ services: AppServices) {
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        // Locking the phone mustn't end the cast: the phone is serving the video.
        options.suspendSessionsWhenBackgrounded = false
        // The TV goes idle when the phone stops serving.
        options.stopReceiverApplicationWhenEndingSession = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        let cast = CastController(context: services.container.mainContext, diagnostics: services.diagnostics)
        cast.playback = services.playback
        services.playback.cast = cast
        GCKCastContext.sharedInstance().sessionManager.add(cast)
    }

    private init(context: ModelContext, diagnostics: DiagnosticsLog) {
        self.context = context
        self.diagnostics = diagnostics
        super.init()
        let center = NotificationCenter.default
        audioObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                MainActor.assumeIsolated { self?.audioInterrupted(ended: type == .ended) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isServing else { return }
                    self.keepAlive = nil
                    self.startKeepAlive()
                }
            }
        ]
    }

    func makeButton() -> UIButton {
        let button = GCKUICastButton(frame: .zero)
        button.delegate = self
        button.accessibilityIdentifier = "player.cast"
        return button
    }

    /// Throws before anything changes, so the phone's player can carry on.
    func play(_ item: DownloadItem, from position: Double, show: String?) throws(Failure) {
        // Opening the video that's already on the TV brings its controls back.
        if castItem?.id == item.id { return GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls() }
        guard let url = item.localURL, FileManager.default.fileExists(atPath: url.path) else { throw .missingFile }
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
              let client = session.remoteMediaClient else { throw .couldNotServe }
        guard let device = session.device.networkAddress.ipAddress, let deviceAddress = IPv4Address(device),
              let host = CastMediaServer.lanAddress(near: device), let phone = IPv4Address(host) else { throw .notOnSameNetwork }

        var extras: [String: CastMediaServer.Extra] = [:]
        if let poster = try? Data(contentsOf: DownloadStorage.thumbnailURL(for: item.id)) {
            extras["poster.jpg"] = .init(type: "image/jpeg", data: poster)
        }
        let saved = SubtitleStore.saved(for: item.id)
        var subtitles: [(id: Int, name: String, file: SubtitleStore.Saved)] = []
        for (index, file) in saved.enumerated() {
            guard let text = try? String(contentsOf: SubtitleStore.fileURL(of: file, for: item.id), encoding: .utf8) else { continue }
            let name = "subtitles/\(index).vtt"
            extras[name] = .init(type: "text/vtt", data: Data(CastMediaServer.webVTT(text).utf8))
            subtitles.append((index + 1, name, file))
        }
        // The phone fetches the poster too, for Google's controls.
        let newServer: CastMediaServer
        do {
            newServer = try CastMediaServer(host: host, allowedPeers: [deviceAddress, phone], video: url, extras: extras) { [weak self] peer in
                Task { @MainActor in self?.record(nil, "Refused a connection from \(peer)") }
            }
        } catch { throw .couldNotServe }

        // Another video was on the TV: the keep-alive carries on.
        if isServing { saveProgress(closing: true) }
        server?.stop()
        server = newServer
        castItem = item
        mediaLoaded = false
        loadRequest = nil
        let token = UUID()
        playID = token
        item.lastPlayedAt = Date()
        try? context.save()
        startKeepAlive()
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveProgress(closing: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        record(item, "Casting to \(session.device.friendlyName ?? "a Chromecast") from \(Int(position)) s")

        Task {
            let base: URL
            do {
                base = try await newServer.start()
            } catch {
                guard playID == token else { return }
                record(item, "Couldn't start serving the video")
                stopServing(saving: false)
                playback?.showCastMessage(Failure.couldNotServe.message)
                return
            }
            guard playID == token else { return }
            let metadata = GCKMediaMetadata(metadataType: show == nil ? .movie : .tvShow)
            metadata.setString(item.displayTitle, forKey: kGCKMetadataKeyTitle)
            if let show, show != item.displayTitle { metadata.setString(show, forKey: kGCKMetadataKeySeriesTitle) }
            if extras["poster.jpg"] != nil {
                metadata.addImage(GCKImage(url: base.appendingPathComponent("poster.jpg"), width: 640, height: 360))
            }
            let media = GCKMediaInformationBuilder(contentURL: base.appendingPathComponent("video.mp4"))
            media.streamType = .buffered
            // QuickTime files with built-in subtitles too: the Chromecast has no type for them.
            media.contentType = "video/mp4"
            media.metadata = metadata
            media.mediaTracks = subtitles.compactMap {
                GCKMediaTrack(identifier: $0.id, contentIdentifier: base.appendingPathComponent($0.name).absoluteString,
                              contentType: "text/vtt", type: .text, textSubtype: .subtitles,
                              name: $0.file.displayName, languageCode: $0.file.language, customData: nil)
            }
            let request = GCKMediaLoadRequestDataBuilder()
            request.mediaInformation = media.build()
            request.startTime = position
            request.autoplay = true
            let active = PlaybackCoordinator.defaultSiteIndex(saved) + 1
            if subtitles.contains(where: { $0.id == active }) { request.activeTrackIDs = [NSNumber(value: active)] }
            client.add(self)
            let load = client.loadMedia(with: request.build())
            load.delegate = self
            loadRequest = load
        }
    }

    // MARK: Sessions

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        record(nil, "Connected to \(session.device.friendlyName ?? "a Chromecast")")
        playback?.castOpenVideo()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        if isServing { session.remoteMediaClient?.add(self) }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, willEnd session: GCKCastSession) {
        // While the TV can still say where it got to.
        saveProgress(closing: true)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: (any Error)?) {
        record(castItem, "Disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        stopServing(saving: false)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: any Error) {
        record(nil, "Couldn't connect: \(error.localizedDescription)")
        stopServing(saving: false)
    }

    // MARK: Media

    func requestDidComplete(_ request: GCKRequest) {
        guard request === loadRequest else { return }
        mediaLoaded = true
        GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard request === loadRequest else { return }
        record(castItem, "The Chromecast couldn't load the video: \(error.localizedDescription)")
        stopServing(saving: false)
        playback?.showCastMessage(Self.formatMessage)
    }

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard mediaLoaded, let item = castItem, let mediaStatus else { return }
        // A video cast straight from the library has never been opened on the phone, so has no length yet.
        if item.duration == nil, let duration = mediaStatus.mediaInformation?.streamDuration, duration.isFinite, duration > 0 {
            item.duration = duration
        }
        guard mediaStatus.playerState == .idle else { return }
        switch mediaStatus.idleReason {
        case .finished:
            if item.modelContext != nil, !item.isDeleted {
                item.setWatched(true)
                try? context.save()
            }
            record(item, "Finished on the TV")
            stopServing(saving: false)
        case .error:
            record(item, "The Chromecast stopped with an error")
            stopServing()
            playback?.showCastMessage(Self.formatMessage)
        case .cancelled:
            record(item, "Stopped on the TV")
            stopServing()
        default:
            // `.interrupted` is the next video replacing this one.
            break
        }
    }

    func castButtonDidTap(_ castButton: GCKUICastButton, toPresentDialogFor castState: GCKCastState) {
        // Connected, the dialog is where casting is stopped, so it always opens.
        if castState != .connected, let playback, playback.isShowingHLS {
            playback.showCastMessage(Self.hlsMessage)
            return
        }
        GCKCastContext.sharedInstance().presentCastDialog()
    }

    // MARK: Serving

    private func saveProgress(closing: Bool) {
        guard mediaLoaded, let item = castItem, item.modelContext != nil, !item.isDeleted, let client else { return }
        item.recordPosition(client.approximateStreamPosition(), duration: item.duration, closing: closing)
        try? context.save()
    }

    private func stopServing(saving: Bool = true) {
        guard isServing else { return }
        if saving { saveProgress(closing: true) }
        playID = UUID()
        progressTimer?.invalidate()
        progressTimer = nil
        server?.stop()
        server = nil
        castItem = nil
        mediaLoaded = false
        loadRequest = nil
        keepAlive?.stop()
        keepAlive = nil
        // A video still open on the phone (an HLS one) keeps the session.
        guard playback?.controller.player == nil else { return }
        // Deactivation can block briefly, so keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// iOS suspends a background app unless it plays audio, and a suspended phone stops serving the TV.
    private func startKeepAlive() {
        guard keepAlive?.isPlaying != true else { return }
        do {
            // Mixed, so music played on the phone meanwhile doesn't stop the cast.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try keepAlive ?? AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.play()
            keepAlive = player
        } catch {
            record(castItem, "Couldn't keep the app running in the background: \(error.localizedDescription)")
        }
    }

    private func audioInterrupted(ended: Bool) {
        guard isServing else { return }
        record(castItem, ended ? "Audio interruption ended; keeping the app running again" : "Audio interrupted (a call?)")
        if ended { startKeepAlive() }
    }

    /// One second of silent 8 kHz 16-bit mono WAV.
    private static let silence: Data = {
        let rate: UInt32 = 8_000
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append(UInt32(36 + rate * 2)); append("WAVEfmt ")
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        append("data"); append(UInt32(rate * 2))
        data.append(Data(count: Int(rate * 2)))
        return data
    }()

    /// Never logs the served URL: its path carries the token.
    private func record(_ item: DownloadItem?, _ note: String) {
        diagnostics.record(event: "cast", url: item?.localURL?.absoluteString ?? "app://cast", note: note)
    }
}
