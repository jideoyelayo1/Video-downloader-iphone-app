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

    let controller = AVPlayerViewController()
    private let context: ModelContext
    private let diagnostics: DiagnosticsLog
    private var item: DownloadItem?
    private var captionGroup: AVMediaSelectionGroup?
    private var captionOptions: [AVMediaSelectionOption] = []
    private var timeObserver: Any?
    private var loadID = UUID()
    private var playbackEnded = false
    private(set) var isInPiP = false

    init(context: ModelContext, diagnostics: DiagnosticsLog) {
        self.context = context
        self.diagnostics = diagnostics
        super.init()
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.view.backgroundColor = .black
        controller.entersFullScreenWhenPlaybackBegins = true
        NotificationCenter.default.addObserver(self, selector: #selector(didFinishPlayback(_:)),
                                               name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
    }

    func open(_ newItem: DownloadItem, at position: Double) {
        close()
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
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else {
            if loadID == token {
                diagnostics.record(event: "captions", url: asset.url.absoluteString,
                                   note: "No caption track in saved media; the source site may provide captions separately")
            }
            return
        }
        guard loadID == token else { return }
        let cached = asset.assetCache?.mediaSelectionOptions(in: group)
        let options = cached ?? group.options
        captionGroup = group
        captionOptions = options
        captionNames = options.map { $0.displayName }
        if let preferred = try? await asset.load(.preferredMediaSelection),
           let selected = preferred.selectedMediaOption(in: group),
           let index = options.firstIndex(of: selected) {
            playerItem.select(selected, in: group)
            selectedCaption = index
        } else if let first = options.first {
            playerItem.select(first, in: group)
            selectedCaption = 0
        }
        if let selectedCaption {
            diagnostics.record(event: "captions", url: asset.url.absoluteString,
                               note: "Selected \(options[selectedCaption].displayName) by default")
        }
        if options.isEmpty {
            diagnostics.record(event: "captions", url: asset.url.absoluteString,
                               note: group.options.isEmpty ? "No caption track in saved media" : "Tracks advertised but absent from offline package")
        }
    }

    func chooseCaption(_ index: Int?) {
        guard let group = captionGroup, let playerItem = controller.player?.currentItem else { return }
        let option = index.flatMap { captionOptions.indices.contains($0) ? captionOptions[$0] : nil }
        playerItem.select(option, in: group)
        selectedCaption = index
        diagnostics.record(event: "captions", url: item?.localURL?.absoluteString ?? "app://player", note: option?.displayName ?? "Off")
    }

    func close() {
        loadID = UUID()
        savePosition()
        if let timeObserver, let player = controller.player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
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

    @objc private func didFinishPlayback(_ notification: Notification) {
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
                        Button("Off") { playback.chooseCaption(nil) }
                        ForEach(Array(playback.captionNames.enumerated()), id: \.offset) { index, name in
                            Button(name) { playback.chooseCaption(index) }
                        }
                    }
                } label: { Label("Captions", systemImage: "captions.bubble") }
                    .accessibilityIdentifier("player.captions")
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
