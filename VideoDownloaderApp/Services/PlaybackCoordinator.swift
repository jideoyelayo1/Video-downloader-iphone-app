import AVFoundation
import AVKit
import SwiftData
import SwiftUI

/// Plays saved videos in AVKit's own full-screen player, so there is one set of controls: AVKit's
/// close button, title, transport, AirPlay, Picture in Picture and subtitle menu. Site subtitles
/// (separate files AVKit can't list) get one extra button that shows and fades with taps.
@MainActor
final class PlaybackCoordinator: NSObject, ObservableObject, @preconcurrency AVPlayerViewControllerDelegate {
    @Published private(set) var isPresented = false
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
    /// Forced-only tracks (signs and foreign-language lines) aren't listed: like AVKit, the app
    /// selects one as "Off".
    private var captionOptions: [AVMediaSelectionOption] = []
    private var forcedCaptionOption: AVMediaSelectionOption?
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
    private var pictureInPictureStarting = false
    /// False in unit tests, which exercise playback without presenting view controllers.
    private let presentsPlayer: Bool
    private var subtitlesButton: UIButton?
    private var controlsSync: Timer?
    private weak var avkitCloseButton: UIView?
    private var selectionObserver: NSObjectProtocol?
    /// Set while the app changes the selection, so only the viewer's own choices are remembered.
    private var applyingCaption = false
    /// AVKit applies its own subtitle preference just after it takes over a new player, which
    /// would undo the viewer's remembered choice. Changes in this window are reverted.
    private var automaticSelectionWindowEnd = Date.distantPast
    private var automaticSelectionReverts = 0

    init(context: ModelContext, diagnostics: DiagnosticsLog, preferences: UserDefaults = .standard, presentsPlayer: Bool = true) {
        self.context = context
        self.diagnostics = diagnostics
        self.preferences = preferences
        self.presentsPlayer = presentsPlayer
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
        controller.modalPresentationStyle = .fullScreen
        controller.view.backgroundColor = .black
        controller.view.accessibilityIdentifier = "player.video"
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
        guard let url = newItem.localURL, FileManager.default.fileExists(atPath: url.path) else {
            item = nil
            showError("The saved video file is missing. Delete it and download the video again.")
            return
        }
        isLoading = true
        presentPlayer()
        Task {
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
            playerItem.externalMetadata = [Self.titleMetadata(newItem.title)]
            if let preferred = try? await asset.load(.preferredMediaSelection),
               let (group, option) = await HLSMediaSelections.audibleOption(for: asset, preferred: preferred) {
                playerItem.select(option, in: group)
            }
            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = false
            // Selections then change only when the app or the viewer chooses, so a change seen in
            // AVKit's subtitle menu can be remembered as the viewer's.
            player.appliesMediaSelectionCriteriaAutomatically = false
            guard loadID == token else { return }
            controller.player = player
            await loadCaptions(from: asset, playerItem: playerItem, token: token)
            guard loadID == token else { return }
            automaticSelectionWindowEnd = Date().addingTimeInterval(1.5)
            automaticSelectionReverts = 0
            observeSelection(of: playerItem)
            installSubtitlesButton(for: player)
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
        let all = group.map { asset.assetCache?.mediaSelectionOptions(in: $0) ?? $0.options } ?? []
        let embedded = all.filter { !Self.isForcedOnly($0) }
        let preferredOption = group.flatMap { preferred?.selectedMediaOption(in: $0) }
        forcedCaptionOption = all.first { Self.isForcedOnly($0) && $0.extendedLanguageTag == preferredOption?.extendedLanguageTag }
            ?? all.first(where: Self.isForcedOnly)
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
            // The system often prefers the forced-only track; captions "on" means full subtitles,
            // in the preferred track's language when there is one.
            defaultIndex = preferredOption.flatMap { embedded.firstIndex(of: $0) }
                ?? embedded.firstIndex { $0.extendedLanguageTag != nil && $0.extendedLanguageTag == preferredOption?.extendedLanguageTag }
                ?? 0
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
        applyingCaption = true
        defer { applyingCaption = false; refreshSubtitlesMenu() }
        if let group = captionGroup {
            // Off (or a site subtitle) selects the forced-only track, as AVKit's own Off does.
            let embedded = index.flatMap { $0 < captionOptions.count ? captionOptions[$0] : nil } ?? forcedCaptionOption
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

    // MARK: AVKit's subtitle menu and the site subtitles button

    /// Remembers choices made in AVKit's own subtitle menu, and hides a site subtitle it replaces.
    private func observeSelection(of playerItem: AVPlayerItem) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                                                                   object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerMenuChangedSelection() }
        }
    }

    private func playerMenuChangedSelection() {
        guard !applyingCaption, let group = captionGroup, let playerItem = controller.player?.currentItem else { return }
        let selected = playerItem.currentMediaSelection.selectedMediaOption(in: group)
        // A forced-only track is AVKit's Off.
        let index = selected.flatMap { captionOptions.firstIndex(of: $0) }
        let showingSite = selectedCaption.map { $0 >= captionOptions.count } ?? false
        // The notification also arrives, later, for the app's own selections: only a selection
        // that differs from the app's state is the viewer's. With a site subtitle showing, the
        // embedded selection is off.
        if showingSite ? index == nil : index == selectedCaption { return }
        if Date() < automaticSelectionWindowEnd && automaticSelectionReverts < 3 {
            automaticSelectionReverts += 1
            applyCaption(selectedCaption, to: playerItem)
            diagnostics.record(event: "captions", url: item?.localURL?.absoluteString ?? "app://player",
                               note: "Kept " + (selectedCaption.map { captionNames[$0] } ?? "Off") + " over the player's automatic choice")
            return
        }
        if index != nil { showSiteSubtitle(nil) }
        selectedCaption = index
        refreshSubtitlesMenu()
        let option = index.map { preferenceOptions[$0] }
        preferences.set(CaptionPreference.storedValue(for: option), forKey: CaptionPreference.defaultsKey)
        diagnostics.record(event: "captions", url: item?.localURL?.absoluteString ?? "app://player",
                           note: (index.map { captionNames[$0] } ?? "Off") + " (player menu)")
    }

    /// AVKit can't list subtitle files that aren't part of the media, so videos saved with site
    /// subtitles get one button beside AVKit's own. It appears and fades with AVKit's controls.
    private func installSubtitlesButton(for player: AVPlayer) {
        guard !siteSubtitles.isEmpty, subtitlesButton == nil else { return }
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.72)
            configuration.cornerStyle = .capsule
        }
        configuration.image = UIImage(systemName: "captions.bubble")
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "player.captions"
        button.accessibilityLabel = "Subtitles"
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(button)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48),
            button.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16)
        ])
        subtitlesButton = button
        refreshSubtitlesMenu()
        // AVKit doesn't report when its controls show or hide, so follow its close button.
        controlsSync = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.matchAVKitControls() }
        }
    }

    private func matchAVKitControls() {
        guard let subtitlesButton else { return }
        let target: CGFloat = avkitControlsVisible() == false ? 0 : 1
        guard subtitlesButton.alpha != target else { return }
        UIView.animate(withDuration: 0.25) { subtitlesButton.alpha = target }
    }

    /// Whether AVKit is showing its controls, judged by its close button; nil if it can't be found,
    /// in which case the subtitles button simply stays visible.
    private func avkitControlsVisible() -> Bool? {
        if avkitCloseButton?.window == nil { avkitCloseButton = Self.view(in: controller.view, identifier: "Close Button") }
        guard let closeButton = avkitCloseButton else { return nil }
        var view: UIView? = closeButton
        var alpha: CGFloat = 1
        while let current = view, current !== controller.view {
            if current.isHidden { return false }
            alpha *= current.alpha
            view = current.superview
        }
        return alpha > 0.05
    }

    private static func view(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let match = view(in: subview, identifier: identifier) { return match }
        }
        return nil
    }

    private func refreshSubtitlesMenu() {
        guard let subtitlesButton else { return }
        let offset = captionOptions.count
        let off = UIAction(title: "Off", state: selectedCaption == nil ? .on : .off) { [weak self] _ in self?.chooseCaption(nil) }
        let site = siteSubtitles.indices.map { index in
            UIAction(title: captionNames[offset + index], state: selectedCaption == offset + index ? .on : .off) { [weak self] _ in
                self?.chooseCaption(offset + index)
            }
        }
        subtitlesButton.menu = UIMenu(title: "Subtitles from the site", children: [off] + site)
        subtitlesButton.accessibilityValue = selectedCaption.map { captionNames[$0] } ?? "Off"
    }

    private static func titleMetadata(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    // MARK: Presentation

    private func presentPlayer() {
        isPresented = true
        guard presentsPlayer, controller.presentingViewController == nil, let presenter = Self.topViewController() else { return }
        // A text field left focused in another tab would otherwise bring its keyboard back over the
        // player whenever a menu opens.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    func clearError() { errorMessage = nil }

    private func showError(_ message: String) {
        errorMessage = message
        diagnostics.record(event: "playback-error", url: item?.localURL?.absoluteString ?? "app://player", note: message)
    }

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

    static func isForcedOnly(_ option: AVMediaSelectionOption) -> Bool {
        option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
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
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        controlsSync?.invalidate()
        controlsSync = nil
        subtitlesButton?.removeFromSuperview()
        subtitlesButton = nil
        controller.player?.pause()
        controller.player = nil
        // Closing with Picture in Picture running is the system's job; otherwise leave full screen.
        if presentsPlayer, !wasInPiP, controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.dismiss(animated: true)
        }
        item = nil
        captionGroup = nil
        captionOptions = []
        forcedCaptionOption = nil
        captionNames = []
        selectedCaption = nil
        errorMessage = nil
        isLoading = false
        isPresented = false
        isInPiP = false
        pictureInPictureStarting = false
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
        let url = item?.localURL?.absoluteString ?? "app://player"
        // Leave full screen first; an alert can't appear over a player that is still closing.
        let presented = presentsPlayer && controller.presentingViewController != nil
        close()
        diagnostics.record(event: "playback-error", url: url, note: message)
        if presented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.errorMessage = message }
        } else {
            errorMessage = message
        }
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

    /// AVKit's close button. Picture in Picture also leaves full screen, but playback continues there.
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            MainActor.assumeIsolated {
                guard let self, !context.isCancelled, playerViewController === self.controller else { return }
                if self.isInPiP || self.pictureInPictureStarting {
                    self.isPresented = false
                } else {
                    self.close()
                }
            }
        }
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { true }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPictureStarting = true
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPiP = true
        pictureInPictureStarting = false
        diagnostics.record(event: "pip", url: item?.localURL?.absoluteString ?? "app://player", note: "Started")
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        isInPiP = false
        pictureInPictureStarting = false
        diagnostics.record(event: "pip-error", url: item?.localURL?.absoluteString ?? "app://player", note: error.localizedDescription)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isInPiP = false
        savePosition()
        diagnostics.record(event: "pip", url: item?.localURL?.absoluteString ?? "app://player", note: "Stopped")
        // Closed from the Picture in Picture window rather than returned to the app.
        if presentsPlayer, playerViewController === controller, controller.presentingViewController == nil { close() }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard presentsPlayer, playerViewController.presentingViewController == nil, let presenter = Self.topViewController() else {
            completionHandler(true)
            return
        }
        isPresented = true
        presenter.present(playerViewController, animated: true) { completionHandler(true) }
    }
}
