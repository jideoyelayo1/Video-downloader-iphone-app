import AVFoundation
import AVKit
import SwiftData
import SwiftUI

/// Owns the AVPlayerViewController across SwiftUI presentation and PiP transitions.
@MainActor
final class PlaybackCoordinator: NSObject, ObservableObject, @preconcurrency AVPlayerViewControllerDelegate {
    @Published var isPresented = false
    @Published private(set) var title = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var captionNames: [String] = []
    @Published private(set) var selectedCaption: Int? = nil

    /// One controller per opened video, kept across its SwiftUI presentations and Picture in Picture.
    /// Re-hosting a single controller for every video kept each earlier presentation's views alive
    /// (about 0.75 MB per video opened).
    private(set) var controller: AVPlayerViewController
    private let context: ModelContext
    private let diagnostics: DiagnosticsLog
    private let preferences: UserDefaults
    private var item: DownloadItem?
    private var captionGroup: AVMediaSelectionGroup?
    /// Caption tracks inside the saved media. `captionNames` lists these first, then `siteSubtitles`.
    private var captionOptions: [AVMediaSelectionOption] = []
    /// Subtitle files the site's player offered, saved with the download and drawn by `subtitleOverlay`.
    private var siteSubtitles: [SubtitleStore.Saved] = []
    private var siteCues: [Int: [SubtitleCue]] = [:]
    private var subtitleObserver: Any?
    private var subtitleOverlay: SubtitleOverlayView?
    private var videoBoundsObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadID = UUID()
    private var playbackEnded = false
    private(set) var isInPiP = false

    init(context: ModelContext, diagnostics: DiagnosticsLog, preferences: UserDefaults = .standard) {
        self.context = context
        self.diagnostics = diagnostics
        self.preferences = preferences
        controller = Self.makeController()
        super.init()
        controller.delegate = self
        // AVFoundation may post this off the main thread; the handler writes main-context SwiftData state.
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                                             queue: .main) { [weak self] notification in
            MainActor.assumeIsolated { self?.didFinishPlayback(notification) }
        }
    }

    private static func makeController() -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.view.backgroundColor = .black
        controller.entersFullScreenWhenPlaybackBegins = true
        return controller
    }

    func open(_ newItem: DownloadItem, at position: Double) {
        // The next video activates the session again right away.
        close(releasingAudioSession: false)
        controller.delegate = nil
        controller = Self.makeController()
        controller.delegate = self
        let token = UUID()
        loadID = token
        item = newItem
        title = newItem.title
        isLoading = true
        isPresented = true
        Task {
            guard let url = newItem.localURL, FileManager.default.fileExists(atPath: url.path) else {
                showFailure("The saved video file is missing.", token: token)
                return
            }
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true else {
                showFailure("This saved video cannot be played on iPhone. Choose another source in Browse.", token: token)
                return
            }
            if newItem.kind == .hls, await HLSMediaSelections.isOfflineAudioMissing(in: asset) {
                showFailure("This saved stream has no offline audio track. Download it again from the master playlist.", token: token)
                return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                diagnostics.record(event: "playback", url: url.absoluteString, note: "Audio session: \(error.localizedDescription)")
            }
            guard loadID == token else { return }
            let playerItem = AVPlayerItem(asset: asset)
            if let preferred = try? await asset.load(.preferredMediaSelection),
               let (group, option) = await HLSMediaSelections.audibleOption(for: asset, preferred: preferred) {
                playerItem.select(option, in: group)
            }
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = false
            guard loadID == token else { return }
            controller.player = player
            await loadCaptions(from: asset, playerItem: playerItem, token: token)
            guard loadID == token else { return }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.savePosition() }
            }
            isLoading = false
            if position > 0 {
                player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { _ in player.play() }
            } else { player.play() }
            diagnostics.record(event: "playback", url: url.absoluteString, note: "Started; captions=\(captionNames.count)")
        }
    }

    private func loadCaptions(from asset: AVURLAsset, playerItem: AVPlayerItem, token: UUID) async {
        let group = try? await asset.loadMediaSelectionGroup(for: .legible)
        let preferred = try? await asset.load(.preferredMediaSelection)
        guard loadID == token else { return }
        let embedded = group.map { asset.assetCache?.mediaSelectionOptions(in: $0) ?? $0.options } ?? []
        let site = item.map { SubtitleStore.saved(for: $0.id) } ?? []
        captionGroup = group
        captionOptions = embedded
        siteSubtitles = site
        siteCues = [:]
        captionNames = Self.menuNames(embedded: embedded.map(\.displayName), site: site.map(\.displayName))
        guard !captionNames.isEmpty else {
            let note = group.map { $0.options.isEmpty ? "No caption track in saved media" : "Tracks advertised but absent from offline package" }
                ?? "No caption track in saved media; the source site may provide captions separately"
            diagnostics.record(event: "captions", url: asset.url.absoluteString, note: note)
            return
        }
        let defaultIndex: Int?
        if !embedded.isEmpty {
            defaultIndex = group.flatMap { preferred?.selectedMediaOption(in: $0) }.flatMap { embedded.firstIndex(of: $0) } ?? 0
        } else {
            defaultIndex = embedded.count + Self.defaultSiteIndex(site)
        }
        // Respect the viewer's last choice, including Off, instead of turning captions on for every video.
        let stored = preferences.string(forKey: CaptionPreference.defaultsKey)
        let choice = CaptionPreference.index(for: stored, in: preferenceOptions, defaultIndex: defaultIndex)
        applyCaption(choice, to: playerItem)
        diagnostics.record(event: "captions", url: asset.url.absoluteString,
                           note: (choice.map { "Selected \(captionNames[$0])" } ?? "Captions off")
                               + (stored == nil ? " by default" : " (remembered)") + "; \(embedded.count) in media, \(site.count) from site")
    }

    func chooseCaption(_ index: Int?) {
        guard let playerItem = controller.player?.currentItem else { return }
        applyCaption(index, to: playerItem)
        let option = index.flatMap { preferenceOptions.indices.contains($0) ? preferenceOptions[$0] : nil }
        preferences.set(CaptionPreference.storedValue(for: option), forKey: CaptionPreference.defaultsKey)
        diagnostics.record(event: "captions", url: item?.localURL?.absoluteString ?? "app://player", note: index.map { captionNames[$0] } ?? "Off")
    }

    /// Selects an embedded track through AVFoundation, or draws a site subtitle file over the video.
    private func applyCaption(_ index: Int?, to playerItem: AVPlayerItem) {
        let index = index.flatMap { captionNames.indices.contains($0) ? $0 : nil }
        if let group = captionGroup {
            let embedded = index.flatMap { $0 < captionOptions.count ? captionOptions[$0] : nil }
            if embedded != nil || group.allowsEmptySelection { playerItem.select(embedded, in: group) }
        }
        showSiteSubtitle(index.flatMap { $0 >= captionOptions.count ? $0 - captionOptions.count : nil })
        selectedCaption = index
    }

    private func showSiteSubtitle(_ siteIndex: Int?) {
        if let subtitleObserver, let player = controller.player { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
        guard let siteIndex, siteSubtitles.indices.contains(siteIndex), let item, let player = controller.player else {
            subtitleOverlay?.text = nil
            return
        }
        let cues = siteCues[siteIndex] ?? {
            let file = SubtitleStore.fileURL(of: siteSubtitles[siteIndex], for: item.id)
            let parsed = (try? String(contentsOf: file, encoding: .utf8)).map(SubtitleParser.cues(from:)) ?? []
            siteCues[siteIndex] = parsed
            return parsed
        }()
        let overlay = installSubtitleOverlay()
        overlay.text = SubtitleParser.text(at: player.currentTime().seconds, in: cues)
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 8), queue: .main) { [weak overlay] time in
            MainActor.assumeIsolated { overlay?.text = SubtitleParser.text(at: time.seconds, in: cues) }
        }
    }

    private func installSubtitleOverlay() -> SubtitleOverlayView {
        if let subtitleOverlay, subtitleOverlay.superview === controller.contentOverlayView { return subtitleOverlay }
        let overlay = SubtitleOverlayView(frame: controller.contentOverlayView?.bounds ?? .zero)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.contentOverlayView?.addSubview(overlay)
        overlay.videoFrame = controller.videoBounds
        videoBoundsObservation = controller.observe(\.videoBounds, options: [.new]) { [weak overlay] controller, _ in
            let bounds = controller.videoBounds
            DispatchQueue.main.async { overlay?.videoFrame = bounds }
        }
        subtitleOverlay = overlay
        return overlay
    }

    /// The site subtitle text currently drawn over the video.
    var siteSubtitleText: String? { subtitleOverlay?.text }

    /// Embedded and site tracks in one list, for the remembered choice.
    private var preferenceOptions: [CaptionPreference.Option] {
        captionOptions.map(Self.preferenceOption)
            + siteSubtitles.map { CaptionPreference.Option(language: $0.language, name: $0.label.isEmpty ? $0.displayName : $0.label) }
    }

    /// Menu names, marking site files that share a name with an embedded track.
    static func menuNames(embedded: [String], site: [String]) -> [String] {
        let taken = Set(embedded)
        return embedded + site.map { taken.contains($0) ? "\($0) (site)" : $0 }
    }

    /// A track in the viewer's language, else the site's default, else the first. Sites mark their
    /// first track as default regardless of the viewer (***REMOVED*** marks Arabic).
    static func defaultSiteIndex(_ site: [SubtitleStore.Saved], preferredLanguages: [String] = Locale.preferredLanguages) -> Int {
        func base(_ tag: String?) -> String? { tag?.split(separator: "-").first.map { $0.lowercased() } }
        for language in preferredLanguages.compactMap(base) {
            if let match = site.firstIndex(where: { base($0.language) == language }) { return match }
        }
        return site.firstIndex(where: \.isDefault) ?? 0
    }

    private static func preferenceOption(_ option: AVMediaSelectionOption) -> CaptionPreference.Option {
        CaptionPreference.Option(language: option.extendedLanguageTag ?? option.locale?.identifier, name: option.displayName)
    }

    /// - Parameter releasingAudioSession: lets music or podcasts paused by playback resume.
    func close(releasingAudioSession: Bool = true) {
        let wasInPiP = isInPiP
        loadID = UUID()
        savePosition()
        if let timeObserver, let player = controller.player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let subtitleObserver, let player = controller.player { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
        videoBoundsObservation = nil
        subtitleOverlay?.removeFromSuperview()
        subtitleOverlay = nil
        siteSubtitles = []
        siteCues = [:]
        controller.player?.pause()
        controller.player = nil
        item = nil
        captionGroup = nil
        captionOptions = []
        captionNames = []
        selectedCaption = nil
        errorMessage = nil
        isLoading = false
        isPresented = false
        isInPiP = false
        playbackEnded = false
        if releasingAudioSession && !wasInPiP {
            // Deactivation can block briefly, so keep it off the main thread.
            DispatchQueue.global(qos: .utility).async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func showFailure(_ message: String, token: UUID) {
        guard loadID == token else { return }
        isLoading = false
        errorMessage = message
        diagnostics.record(event: "playback-error", url: item?.localURL?.absoluteString ?? "app://player", note: message)
    }

    private func savePosition() {
        guard !playbackEnded, let item,
              let seconds = controller.player?.currentTime().seconds,
              seconds.isFinite, seconds > 0 else { return }
        item.playbackPosition = seconds
        try? context.save()
    }

    private func didFinishPlayback(_ notification: Notification) {
        guard let current = controller.player?.currentItem, notification.object as? AVPlayerItem === current else { return }
        playbackEnded = true
        item?.playbackPosition = 0
        try? context.save()
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPiP = true
        diagnostics.record(event: "pip", url: item?.localURL?.absoluteString ?? "app://player", note: "Started")
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        isInPiP = false
        diagnostics.record(event: "pip-error", url: item?.localURL?.absoluteString ?? "app://player", note: error.localizedDescription)
        errorMessage = "Picture in Picture could not start: \(error.localizedDescription)"
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPiP = false
        savePosition()
        diagnostics.record(event: "pip", url: item?.localURL?.absoluteString ?? "app://player", note: "Stopped")
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if isPresented {
            completionHandler(true)
        } else {
            isPresented = true
            // Let SwiftUI attach the retained controller before finishing the
            // system's return-to-app transition.
            DispatchQueue.main.async { completionHandler(true) }
        }
    }
}

struct PersistentPlayerScreen: View {
    @EnvironmentObject private var playback: PlaybackCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if playback.controller.player != nil {
                PlayerControllerView(controller: playback.controller)
                    // A new video brings a new controller; never keep hosting the previous one.
                    .id(ObjectIdentifier(playback.controller))
                    .ignoresSafeArea()
                    .accessibilityIdentifier("player.video")
            } else if playback.isLoading {
                ProgressView("Loading video").tint(.white).foregroundStyle(.white)
            } else if let error = playback.errorMessage {
                ContentUnavailableView("Unable to play video", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button("Done") { playback.close() }
                    .accessibilityIdentifier("player.done")
                Spacer()
                Text(playback.title).lineLimit(1).font(.subheadline.bold())
                Spacer()
                Menu {
                    if playback.captionNames.isEmpty {
                        Button("No caption track in saved video") {}.disabled(true)
                        Button("Try subtitles in the site's player in Browse") {}.disabled(true)
                    } else {
                        // An inline picker checkmarks the active choice, which plain buttons never showed.
                        Picker("Captions", selection: Binding(get: { playback.selectedCaption }, set: { playback.chooseCaption($0) })) {
                            Text("Off").tag(Int?.none)
                            ForEach(Array(playback.captionNames.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(Int?.some(index))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: { Label("Captions", systemImage: playback.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill") }
                    .accessibilityIdentifier("player.captions")
                    .accessibilityValue(playback.selectedCaption.map { playback.captionNames[$0] } ?? "Off")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(.black.opacity(0.72))
        }
        .alert("Playback issue", isPresented: Binding(get: { playback.errorMessage != nil && playback.controller.player != nil },
                                                       set: { _ in })) {
            Button("OK") { playback.close() }
        } message: { Text(playback.errorMessage ?? "") }
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    let controller: AVPlayerViewController
    func makeUIViewController(context: Context) -> AVPlayerViewController { controller }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
