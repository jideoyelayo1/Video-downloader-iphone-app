import AVFoundation
import AVKit
import MediaPlayer
import SwiftData
import SwiftUI

/// AVKit's own full-screen player, so one set of controls; site subtitles AVKit can't list get an extra button.
@MainActor
final class PlaybackCoordinator: NSObject, ObservableObject, @preconcurrency AVPlayerViewControllerDelegate {
    @Published private(set) var isPresented = false
    @Published private(set) var title = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var captionNames: [String] = []
    @Published private(set) var selectedCaption: Int? = nil
    /// A finished episode to ask about deleting once the player has closed.
    @Published private(set) var finishedEpisode: DownloadItem?

    /// One controller per video: re-hosting one kept every earlier presentation's views alive (~0.75 MB each).
    private(set) var controller: AVPlayerViewController
    private let context: ModelContext
    private let diagnostics: DiagnosticsLog
    private let preferences: UserDefaults
    private var item: DownloadItem?
    private var captionGroup: AVMediaSelectionGroup?
    /// Listed first in `captionNames`, then `siteSubtitles`; forced-only tracks are left out, as in AVKit.
    private var captionOptions: [AVMediaSelectionOption] = []
    private var forcedCaptionOption: AVMediaSelectionOption?
    /// Whether "no captions" keeps the forced-only track, as the viewer last left it.
    private var offKeepsForced = true
    private var siteSubtitles: [SubtitleStore.Saved] = []
    private var siteCues: [Int: [SubtitleCue]] = [:]
    /// Seconds a site subtitle is shown later than its file says (earlier if negative), for files out of sync.
    private(set) var subtitleDelay: Double = 0
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
    private var showButton: UIButton?
    private var sleepTimerButton: UIButton?
    /// The screen lock stays on from one episode to the next.
    private var lockWindow: PlayerLockWindow?
    var isScreenLocked: Bool { lockWindow != nil }
    enum SleepTimerOption: Equatable {
        case minutes(Int)
        case endOfVideo
    }
    private(set) var sleepTimerOption: SleepTimerOption?
    private(set) var sleepTimerDeadline: Date?
    private var sleepTimer: Timer?
    private var sleepTimerForegroundObserver: NSObjectProtocol?
    private var sleepTimerPlaybackObservation: NSKeyValueObservation?
    /// Keeps a pending load or end notification from restarting playback after the timer fires.
    private var sleepTimerHasExpired = false
    private var sideControls: UIStackView?
    private var skipIntroButton: UIButton?
    private var showObserver: Any?
    private var reachedCredits = false
    private var skippedIntroAutomatically = false
    private var controlsSync: Timer?
    private weak var avkitCloseButton: UIView?
    private var selectionObserver: NSObjectProtocol?
    /// Set while the app changes the selection, so only the viewer's own choices are remembered.
    private var applyingCaption = false
    /// AVKit re-applies its subtitle preference just after taking over a player; changes until then are reverted.
    private var automaticSelectionWindowEnd = Date.distantPast
    private var automaticSelectionReverts = 0
    var shows: ShowStore?
    private var upNextItem: DownloadItem?
    private var upNextPanel: UIView?
    private var upNextButton: UIButton?
    private var upNextFill: NSLayoutConstraint?
    private var upNextTimer: Timer?
    private var upNextCountdown = 0
    private var upNextTotal = 0
    var downloads: DownloadManager?
    /// Nil in unit tests, which run without Google Cast.
    var cast: CastController?
    /// A finished episode, deleted once the player has let go of it.
    private var episodeToDelete: DownloadItem?
    private var cardEpisode: DownloadItem?
    private var deleteTicked = false
    private var deleteToggle: UIButton?
    private var askedAboutDeleting = false

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
        // Connected to a Chromecast: saved files play on the TV (HLS packages can't be served to it yet).
        if let cast, cast.isConnected, newItem.kind != .hls {
            close(releasingAudioSession: false)
            do { try cast.play(newItem, from: position, show: shows?.show(for: newItem)?.title) } catch { showCastMessage(error.message) }
            return
        }
        // The next video reactivates the audio session at once; a finished episode reopened isn't deleted.
        close(releasingAudioSession: false, keeping: newItem)
        controller.delegate = nil
        controller = Self.makeController()
        controller.delegate = self
        let token = UUID()
        loadID = token
        item = newItem
        title = newItem.displayTitle
        guard let url = newItem.localURL, FileManager.default.fileExists(atPath: url.path) else {
            item = nil
            showError("The saved video file is missing. Delete it and download the video again.")
            return
        }
        isLoading = true
        newItem.lastPlayedAt = Date()
        try? context.save()
        presentPlayer()
        Task { await load(newItem, from: url, at: position, token: token, into: nil) }
    }

    /// Moves on to the next episode in the same player, so full screen or Picture in Picture carries on.
    func playNext(_ next: DownloadItem) {
        guard sleepTimerTick(), let player = controller.player, let url = next.localURL, FileManager.default.fileExists(atPath: url.path) else { return }
        if episodeToDelete?.id == next.id { episodeToDelete = nil }
        resetItemState()
        let token = UUID()
        loadID = token
        item = next
        title = next.displayTitle
        next.lastPlayedAt = Date()
        try? context.save()
        isLoading = true
        diagnostics.record(event: "playback", url: url.absoluteString, note: "Up next → \(next.displayTitle)")
        let position = !next.isWatched && (next.playbackPosition ?? 0) > 10 ? next.playbackPosition ?? 0 : 0
        Task { await load(next, from: url, at: position, token: token, into: player) }
    }

    private func load(_ newItem: DownloadItem, from url: URL, at position: Double, token: UUID, into existing: AVPlayer?) async {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else {
            showFailure("This saved video cannot be played on iPhone. Choose another source in Browse.", token: token)
            return
        }
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 { newItem.duration = duration }
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
        playerItem.externalMetadata = Self.nowPlayingMetadata(title: newItem.displayTitle, show: shows?.show(for: newItem)?.title,
                                                              artwork: try? Data(contentsOf: DownloadStorage.thumbnailURL(for: newItem.id)))
        if let preferred = try? await asset.load(.preferredMediaSelection),
           let (group, option) = await HLSMediaSelections.audibleOption(for: asset, preferred: preferred) {
            playerItem.select(option, in: group)
        }
        guard loadID == token else { return }
        let player: AVPlayer
        if let existing {
            existing.replaceCurrentItem(with: playerItem)
            player = existing
        } else {
            player = AVPlayer(playerItem: playerItem)
            player.isMuted = false
            if #available(iOS 26.0, *) {
                // iOS 26 re-applies the system subtitle preference over the viewer's choice; iOS 18's Off needs it.
                player.appliesMediaSelectionCriteriaAutomatically = false
            }
            controller.player = player
            sleepTimerPlaybackObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, self.controller.player === player,
                          player.rate > 0, self.sleepTimerHasExpired else { return }
                    // Pressing Play after the timer paused is an explicit request to carry on.
                    self.sleepTimerHasExpired = false
                    self.refreshSleepTimerButton()
                }
            }
        }
        // The finished episode is out of the player now.
        deleteFinishedEpisode()
        await loadCaptions(from: asset, playerItem: playerItem, token: token)
        guard loadID == token else { return }
        automaticSelectionWindowEnd = Date().addingTimeInterval(2)
        automaticSelectionReverts = 0
        observeSelection(of: playerItem)
        installSideControls()
        observeShowPlayback(of: player)
        applyShowSpeed()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePosition()
                self?.rememberSpeedOutsideShows()
            }
        }
        isLoading = false
        if position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { [weak self, weak player] finished in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, finished, self.loadID == token, self.sleepTimerTick() else { return }
                    player.play()
                }
            }
        } else if sleepTimerTick() { player.play() }
        diagnostics.record(event: "playback", url: url.absoluteString, note: "Started; captions=\(captionNames.count)")
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
        subtitleDelay = 0
        captionNames = Self.menuNames(embedded: embedded.map(\.displayName), site: site.map(\.displayName))
        guard !captionNames.isEmpty else {
            let note = group.map { $0.options.isEmpty ? "No caption track in saved media" : "Tracks advertised but absent from offline package" }
                ?? "No caption track in saved media; the source site may provide captions separately"
            diagnostics.record(event: "captions", url: asset.url.absoluteString, note: note)
            return
        }
        let defaultIndex: Int?
        if !embedded.isEmpty {
            // The system often prefers the forced-only track; captions on means full subtitles in its language.
            defaultIndex = preferredOption.flatMap { embedded.firstIndex(of: $0) }
                ?? embedded.firstIndex { $0.extendedLanguageTag != nil && $0.extendedLanguageTag == preferredOption?.extendedLanguageTag }
                ?? 0
        } else {
            defaultIndex = embedded.count + Self.defaultSiteIndex(site)
        }
        // Respect the viewer's last choice, including Off, instead of turning captions on for every video.
        let stored = preferences.string(forKey: CaptionPreference.defaultsKey)
        offKeepsForced = stored != CaptionPreference.off
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

    private func applyCaption(_ index: Int?, to playerItem: AVPlayerItem) {
        let index = index.flatMap { captionNames.indices.contains($0) ? $0 : nil }
        applyingCaption = true
        defer { applyingCaption = false; refreshSubtitlesMenu() }
        if let group = captionGroup {
            // Off (or a site subtitle) selects the forced-only track, as AVKit's own Off does.
            let embedded = index.flatMap { $0 < captionOptions.count ? captionOptions[$0] : nil } ?? (offKeepsForced ? forcedCaptionOption : nil)
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
        overlay.text = SubtitleParser.text(at: player.currentTime().seconds - subtitleDelay, in: cues)
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 8), queue: .main) { [weak self, weak overlay] time in
            MainActor.assumeIsolated { overlay?.text = SubtitleParser.text(at: time.seconds - (self?.subtitleDelay ?? 0), in: cues) }
        }
    }

    private func installSubtitleOverlay() -> SubtitleOverlayView {
        if let subtitleOverlay, subtitleOverlay.superview === controller.contentOverlayView { return subtitleOverlay }
        let overlay = SubtitleOverlayView(frame: controller.contentOverlayView?.bounds ?? .zero)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.contentOverlayView?.addSubview(overlay)
        overlay.videoFrame = controller.videoBounds
        // KVO may report off the main thread; the player's views are read on it.
        videoBoundsObservation = controller.observe(\.videoBounds, options: [.new]) { [weak self] controller, _ in
            Task { @MainActor in self?.subtitleOverlay?.videoFrame = controller.videoBounds }
        }
        subtitleOverlay = overlay
        return overlay
    }

    var siteSubtitleText: String? { subtitleOverlay?.text }

    // MARK: AVKit's subtitle menu and the site subtitles button

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
        // A forced-only track counts as captions off (it is AVKit's Off on iOS 26).
        let index = selected.flatMap { captionOptions.firstIndex(of: $0) }
        let forcedSelected = selected.map(Self.isForcedOnly) ?? false
        let showingSite = selectedCaption.map { $0 >= captionOptions.count } ?? false
        // The app's own selections post this too, later; only one differing from the app's state is the viewer's.
        let unchanged = index == nil
            ? (showingSite || selectedCaption == nil) && (forcedCaptionOption == nil || forcedSelected == offKeepsForced)
            : !showingSite && index == selectedCaption
        if unchanged { return }
        // AVKit re-applied its choice up to three times in a row on iOS 18.
        if Date() < automaticSelectionWindowEnd && automaticSelectionReverts < 6 {
            automaticSelectionReverts += 1
            applyCaption(selectedCaption, to: playerItem)
            diagnostics.record(event: "captions", url: item?.localURL?.absoluteString ?? "app://player",
                               note: "Kept " + (selectedCaption.map { captionNames[$0] } ?? "Off") + " over the player's automatic choice")
            return
        }
        if index != nil { showSiteSubtitle(nil) }
        selectedCaption = index
        if index == nil { offKeepsForced = forcedSelected }
        refreshSubtitlesMenu()
        let stored = index.map { CaptionPreference.storedValue(for: preferenceOptions[$0]) }
            ?? (forcedSelected ? CaptionPreference.forcedOnly : CaptionPreference.off)
        preferences.set(stored, forKey: CaptionPreference.defaultsKey)
        diagnostics.record(event: "captions", url: item?.localURL?.absoluteString ?? "app://player",
                           note: (index.map { captionNames[$0] } ?? (forcedSelected ? "Forced subtitles only" : "Off")) + " (player menu)")
    }

    private func installSideControls() {
        guard sideControls == nil else { return }
        let timerButton = Self.sideButton(systemImage: "moon.zzz", identifier: "player.sleepTimer", label: "Sleep Timer")
        timerButton.accessibilityHint = "Pause playback after a chosen time or at the end of this video."
        timerButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated { completion(self?.sleepTimerMenuElements() ?? []) }
        }])
        sleepTimerButton = timerButton
        let lockButton = Self.sideButton(systemImage: "lock", identifier: "player.lock", label: "Lock Screen")
        lockButton.accessibilityHint = "Ignores touches so the video keeps playing, in the shower say. Tap the lock twice to unlock."
        lockButton.showsMenuAsPrimaryAction = false
        lockButton.addAction(UIAction { [weak self] _ in self?.lockScreen() }, for: .primaryActionTriggered)
        var buttons: [UIButton] = [timerButton]
        if let castButton = cast?.makeButton() {
            // Google's button draws its own images, so it can't take a button configuration.
            castButton.backgroundColor = UIColor(white: 0.12, alpha: 0.72)
            castButton.layer.cornerRadius = 24
            castButton.tintColor = .white
            NSLayoutConstraint.activate([
                castButton.widthAnchor.constraint(equalToConstant: 48),
                castButton.heightAnchor.constraint(equalToConstant: 48)
            ])
            buttons.insert(castButton, at: 0)
        }
        refreshSleepTimerButton()
        if !siteSubtitles.isEmpty {
            let button = Self.sideButton(systemImage: "captions.bubble", identifier: "player.captions", label: "Subtitles")
            subtitlesButton = button
            buttons.append(button)
        }
        if let item, shows?.show(for: item) != nil {
            let button = Self.sideButton(systemImage: "rectangle.stack", identifier: "player.episode", label: "Episode options")
            // Built when opened, so the times and the next episode are current.
            button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated { completion(self?.episodeMenuElements() ?? []) }
            }])
            showButton = button
            buttons.append(button)
        }
        buttons.append(lockButton)
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16)
        ])
        sideControls = stack
        refreshSubtitlesMenu()
        // AVKit doesn't report when its controls show or hide, so follow its close button.
        controlsSync = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.matchAVKitControls() }
        }
    }

    private static func sideButton(systemImage: String, identifier: String, label: String) -> UIButton {
        // Not .glass(): with three glass buttons, AVKit's Close stopped working on a second video (iOS 26.5 sim).
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.72)
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: systemImage)
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48)
        ])
        return button
    }

    private func matchAVKitControls() {
        guard let sideControls else { return }
        let target: CGFloat = isScreenLocked || avkitControlsVisible() == false ? 0 : 1
        guard sideControls.alpha != target else { return }
        UIView.animate(withDuration: 0.25) { sideControls.alpha = target }
    }

    // MARK: Screen lock

    func lockScreen() {
        guard lockWindow == nil, let scene = controller.view.window?.windowScene else { return }
        // Hidden at once rather than when AVKit next fades them.
        controller.showsPlaybackControls = false
        lockWindow = PlayerLockWindow(scene: scene) { [weak self] in self?.unlockScreen() }
        matchAVKitControls()
        diagnostics.record(event: "playback", url: item?.localURL?.absoluteString ?? "app://player", note: "Screen locked")
    }

    func unlockScreen() {
        guard let lockWindow else { return }
        lockWindow.remove()
        self.lockWindow = nil
        controller.showsPlaybackControls = true
        diagnostics.record(event: "playback", url: item?.localURL?.absoluteString ?? "app://player", note: "Screen unlocked")
    }

    // MARK: Sleep timer

    /// The deadline belongs to the playback session, so changing episodes never restarts it.
    func setSleepTimer(_ option: SleepTimerOption?) {
        if option != nil, item == nil { return }
        if case .minutes(let minutes) = option, minutes <= 0 { return }
        sleepTimer?.invalidate()
        sleepTimer = nil
        if let observer = sleepTimerForegroundObserver { NotificationCenter.default.removeObserver(observer) }
        sleepTimerForegroundObserver = nil
        sleepTimerOption = option
        sleepTimerDeadline = nil
        sleepTimerHasExpired = false
        if case .minutes(let minutes) = option {
            sleepTimerDeadline = Date().addingTimeInterval(TimeInterval(minutes) * 60)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.sleepTimerTick() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            sleepTimer = timer
            // Reconcile the deadline immediately after any period when iOS suspended the app.
            sleepTimerForegroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.sleepTimerTick() }
            }
        } else if option == .endOfVideo {
            hideUpNext()
            if playbackEnded { expireSleepTimer() }
        }
        refreshSleepTimerButton()
    }

    /// Also checked before autoplay and after async loads, so a late callback can't play on past the deadline.
    @discardableResult
    func sleepTimerTick(at now: Date = Date()) -> Bool {
        if let deadline = sleepTimerDeadline, now >= deadline { expireSleepTimer() }
        refreshSleepTimerButton(at: now)
        return !sleepTimerHasExpired
    }

    private func expireSleepTimer() {
        setSleepTimer(nil)
        sleepTimerHasExpired = true
        controller.player?.pause()
        hideUpNext()
        // Mid-transition the old player item may still be loaded while `item` is the next episode.
        if !isLoading { savePosition() }
        refreshSleepTimerButton()
        diagnostics.record(event: "playback", url: item?.localURL?.absoluteString ?? "app://player", note: "Sleep timer paused playback")
    }

    private func sleepTimerMenuElements() -> [UIMenuElement] {
        var choices: [UIMenuElement] = [10, 15, 20, 30, 45, 60].map { minutes in
            UIAction(title: "\(minutes) minutes", state: sleepTimerOption == .minutes(minutes) ? .on : .off) { [weak self] _ in
                self?.setSleepTimer(.minutes(minutes))
            }
        }
        choices.append(UIAction(title: "End of video", state: sleepTimerOption == .endOfVideo ? .on : .off) { [weak self] _ in
            self?.setSleepTimer(.endOfVideo)
        })
        if sleepTimerOption != nil {
            choices.append(UIAction(title: "Turn Off Timer", image: UIImage(systemName: "xmark.circle")) { [weak self] _ in
                self?.setSleepTimer(nil)
            })
        }
        return [UIMenu(title: "Sleep Timer", options: .displayInline, children: choices)]
    }

    private func refreshSleepTimerButton(at now: Date = Date()) {
        guard let button = sleepTimerButton else { return }
        let status: String
        if let deadline = sleepTimerDeadline {
            let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
            status = seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        } else if sleepTimerOption == .endOfVideo {
            status = "End"
        } else {
            status = sleepTimerHasExpired ? "Paused" : "Off"
        }
        let subtitle = sleepTimerOption != nil || sleepTimerHasExpired ? status : nil
        if var configuration = button.configuration, configuration.subtitle != subtitle {
            configuration.subtitle = subtitle
            configuration.imagePlacement = .top
            configuration.imagePadding = 2
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 10, weight: .medium))
                return attributes
            }
            button.configuration = configuration
        }
        button.accessibilityValue = sleepTimerOption == .endOfVideo ? "End of video" : status
    }

    // MARK: Shows: episodes, intro and credits, speed

    /// Read twice a second during playback, so it's looked up once per video, not by fetching every show.
    private var currentShow: Show? {
        guard let item, let shows else { return nil }
        if let cached = cachedShow, cached.itemID == item.id { return cached.show }
        let show = shows.show(for: item)
        cachedShow = (item.id, show)
        return show
    }
    private var cachedShow: (itemID: UUID, show: Show?)?

    private func episodeMenuElements() -> [UIMenuElement] {
        guard let item, let show = currentShow, let shows else { return [] }
        var episodes: [UIMenuElement] = []
        if let next = shows.episode(1, from: item) {
            episodes.append(UIAction(title: "Next Episode", subtitle: next.displayTitle, image: UIImage(systemName: "forward.end")) { [weak self] _ in
                self?.playNext(next)
            })
        }
        if let previous = shows.episode(-1, from: item) {
            episodes.append(UIAction(title: "Previous Episode", subtitle: previous.displayTitle, image: UIImage(systemName: "backward.end")) { [weak self] _ in
                self?.playNext(previous)
            })
        }
        var marks: [UIMenuElement] = [
            UIAction(title: "Intro Starts Here", subtitle: show.introStart.map(IntroSkip.timeText)) { [weak self] _ in
                self?.markShow { show, position, _ in show.introStart = position }
            },
            UIAction(title: "Intro Ends Here", subtitle: show.introEnd.map(IntroSkip.timeText)) { [weak self] _ in
                self?.markShow { show, position, _ in show.introEnd = position }
            },
            UIAction(title: "Credits Start Here", subtitle: show.creditsFromEnd.map { IntroSkip.timeText($0) + " before the end" }) { [weak self] _ in
                self?.markShow { show, position, duration in
                    if let duration, duration > position { show.creditsFromEnd = duration - position }
                }
            },
            UIAction(title: "Skip Intro Automatically", state: show.autoSkipIntro ? .on : .off) { [weak self] _ in
                show.autoSkipIntro.toggle()
                self?.shows?.save()
            }
        ]
        if show.hasIntroOrCredits {
            marks.append(UIAction(title: "Clear Intro and Credits", attributes: .destructive) { [weak self] _ in
                show.introStart = nil
                show.introEnd = nil
                show.creditsFromEnd = nil
                self?.shows?.save()
                self?.setSkipIntroVisible(false)
            })
        }
        return [UIMenu(title: show.title, options: .displayInline, children: episodes),
                UIMenu(title: "Intro and Credits (all episodes)", options: .displayInline, children: marks)]
    }

    private func markShow(_ change: (Show, Double, Double?) -> Void) {
        guard let show = currentShow, let position = controller.player?.currentTime().seconds, position.isFinite else { return }
        change(show, position, item?.duration ?? controller.player?.currentItem?.duration.seconds)
        shows?.save()
        diagnostics.record(event: "playback", url: item?.localURL?.absoluteString ?? "app://player",
                           note: "Marked \(show.title): intro \(show.introStart.map(IntroSkip.timeText) ?? "–")–\(show.introEnd.map(IntroSkip.timeText) ?? "–"), credits \(show.creditsFromEnd.map(IntroSkip.timeText) ?? "–") before the end")
    }

    private func observeShowPlayback(of player: AVPlayer) {
        reachedCredits = false
        skippedIntroAutomatically = false
        guard currentShow != nil else { return }
        showObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.showPlaybackTick(at: time.seconds) }
        }
    }

    func showPlaybackTick(at position: Double) {
        guard let item, let show = currentShow else { return }
        let inIntro = IntroSkip.isInIntro(position, start: show.introStart, end: show.introEnd)
        if inIntro && show.autoSkipIntro {
            if !skippedIntroAutomatically {
                skippedIntroAutomatically = true
                skipIntro()
            }
        } else {
            setSkipIntroVisible(inIntro)
        }
        if !reachedCredits, let credits = IntroSkip.creditsStart(duration: item.duration, fromEnd: show.creditsFromEnd), position >= credits {
            reachedCredits = true
            item.setWatched(true)
            try? context.save()
            episodeFinished(item, atCredits: true)
        }
        rememberShowSpeed(show)
    }

    func skipIntro() {
        guard let end = currentShow?.introEnd, let player = controller.player else { return }
        setSkipIntroVisible(false)
        player.seek(to: CMTime(seconds: end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func setSkipIntroVisible(_ visible: Bool) {
        guard presentsPlayer else { return }
        if !visible {
            skipIntroButton?.removeFromSuperview()
            skipIntroButton = nil
            return
        }
        guard skipIntroButton == nil else { return }
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Skip Intro"
        configuration.image = UIImage(systemName: "forward.fill")
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor(white: 0.95, alpha: 0.92)
        configuration.baseForegroundColor = .black
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.skipIntro() })
        button.accessibilityIdentifier = "player.skipIntro"
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(button)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -100)
        ])
        skipIntroButton = button
    }

    private func rememberSpeedOutsideShows() {
        guard currentShow == nil, let rate = controller.selectedSpeed?.rate else { return }
        if abs(rate - 1) < 0.01 { preferences.removeObject(forKey: Self.speedKey) } else { preferences.set(Double(rate), forKey: Self.speedKey) }
    }
    private static let speedKey = "playbackSpeed"

    /// AVKit's speed menu sets `selectedSpeed`; the show keeps the last one chosen.
    private func rememberShowSpeed(_ show: Show) {
        guard let rate = controller.selectedSpeed?.rate else { return }
        let stored: Double? = abs(rate - 1) < 0.01 ? nil : Double(rate)
        guard stored != show.playbackRate else { return }
        show.playbackRate = stored
        shows?.save()
    }

    private func applyShowSpeed() {
        let rate = currentShow.map(\.playbackRate) ?? preferences.object(forKey: Self.speedKey) as? Double
        guard let rate,
              let speed = controller.speeds.first(where: { abs(Double($0.rate) - rate) < 0.01 }) else { return }
        controller.selectSpeed(speed)
    }

    private func configureRemoteCommands() {
        // Only for the player on screen; unit tests drive `playEpisode` directly.
        guard presentsPlayer else { return }
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        guard let item, let shows, item.showID != nil else {
            center.nextTrackCommand.isEnabled = false
            center.previousTrackCommand.isEnabled = false
            return
        }
        center.nextTrackCommand.isEnabled = shows.episode(1, from: item) != nil
        center.previousTrackCommand.isEnabled = shows.episode(-1, from: item) != nil
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.playEpisode(1) == true ? .success : .noSuchContent }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.playEpisode(-1) == true ? .success : .noSuchContent }
        }
    }

    /// `offset` is 1 for the next episode or -1 for the previous.
    @discardableResult
    func playEpisode(_ offset: Int) -> Bool {
        guard sleepTimerTick(), let item, let episode = shows?.episode(offset, from: item) else { return false }
        playNext(episode)
        return true
    }

    /// Judged by AVKit's close button; nil if it can't be found, which leaves the side buttons visible.
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
        var children: [UIMenuElement] = [off] + site
        if let selectedCaption, selectedCaption >= offset {
            let timing = [("Show Earlier", -0.5), ("Show Later", 0.5)].map { title, step in
                UIAction(title: "\(title) (\(step > 0 ? "+" : "−")0.5 s)") { [weak self] _ in self?.shiftSubtitles(by: step) }
            }
            let reset = UIAction(title: "Reset Timing", attributes: subtitleDelay == 0 ? .disabled : []) { [weak self] _ in
                self?.shiftSubtitles(by: -(self?.subtitleDelay ?? 0))
            }
            let delay = subtitleDelay == 0 ? "as in the file" : String(format: "%+.1f s", subtitleDelay)
            children.append(UIMenu(title: "Timing: \(delay)", options: .displayInline, children: timing + [reset]))
        }
        subtitlesButton.menu = UIMenu(title: "Subtitles from the site", children: children)
        subtitlesButton.accessibilityValue = selectedCaption.map { captionNames[$0] } ?? "Off"
    }

    func shiftSubtitles(by seconds: Double) {
        subtitleDelay = ((subtitleDelay + seconds) * 10).rounded() / 10
        if let selectedCaption, selectedCaption >= captionOptions.count { showSiteSubtitle(selectedCaption - captionOptions.count) }
        refreshSubtitlesMenu()
    }

    private static func nowPlayingMetadata(title: String, show: String?, artwork: Data?) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, dataType: String? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            if let dataType { item.dataType = dataType }
            return item
        }
        var items = [item(.commonIdentifierTitle, title as NSString)]
        if let show, show != title { items.append(item(.iTunesMetadataTrackSubTitle, show as NSString)) }
        if let artwork { items.append(item(.commonIdentifierArtwork, artwork as NSData, dataType: kCMMetadataBaseDataType_JPEG as String)) }
        return items
    }

    // MARK: Presentation

    private func presentPlayer() {
        isPresented = true
        guard presentsPlayer, controller.presentingViewController == nil, let presenter = Self.topViewController() else { return }
        // A text field focused in another tab would bring its keyboard over the player whenever a menu opens.
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

    // MARK: Chromecast

    var isShowingHLS: Bool { item?.kind == .hls }

    func castOpenVideo(attempt: Int = 0) {
        guard let cast, cast.isConnected, let item else { return }
        if item.kind == .hls { return showCastMessage(CastController.hlsMessage) }
        // Google's device list is still closing; dismissing the player now would only close the list.
        if controller.presentedViewController != nil {
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.castOpenVideo(attempt: attempt + 1) }
            return
        }
        let seconds = controller.player?.currentTime().seconds ?? 0
        let position = seconds.isFinite && seconds > 0 ? seconds : item.playbackPosition ?? 0
        do { try cast.play(item, from: position, show: shows?.show(for: item)?.title) } catch { return showCastMessage(error.message) }
        // Kept: handing over near the end mustn't delete the file the phone is about to serve.
        close(releasingAudioSession: false, keeping: item)
    }

    /// UIKit alert on the top view controller: the SwiftUI alert can't show over the player or Google's controls.
    func showCastMessage(_ message: String) {
        diagnostics.record(event: "cast", url: item?.localURL?.absoluteString ?? "app://cast", note: message)
        guard presentsPlayer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = UIAlertController(title: "Chromecast", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            Self.topViewController()?.present(alert, animated: true)
        }
    }

    func clearError() { errorMessage = nil }

    private func showError(_ message: String) {
        errorMessage = message
        diagnostics.record(event: "playback-error", url: item?.localURL?.absoluteString ?? "app://player", note: message)
    }

    private var preferenceOptions: [CaptionPreference.Option] {
        captionOptions.map(Self.preferenceOption)
            + siteSubtitles.map { CaptionPreference.Option(language: $0.language, name: $0.label.isEmpty ? $0.displayName : $0.label) }
    }

    static func menuNames(embedded: [String], site: [String]) -> [String] {
        let taken = Set(embedded)
        return embedded + site.map { taken.contains($0) ? "\($0) (site)" : $0 }
    }

    /// Viewer's language first: sites mark a default regardless of the viewer.
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

    /// `kept` is a video about to be reopened, so it isn't deleted as a finished episode.
    func close(releasingAudioSession: Bool = true, keeping kept: DownloadItem? = nil) {
        let wasInPiP = isInPiP
        let presented = presentsPlayer && controller.presentingViewController != nil
        loadID = UUID()
        unlockScreen()
        setSleepTimer(nil)
        sleepTimerPlaybackObservation = nil
        let finished = savePosition(closing: true) || playbackEnded || reachedCredits
        if finished, let item, item.id != kept?.id { closedFinished(item, presented: presented) }
        resetItemState()
        if let kept, episodeToDelete?.id == kept.id { episodeToDelete = nil }
        controller.player?.pause()
        controller.player = nil
        deleteFinishedEpisode()
        // Closing with Picture in Picture running is the system's job; otherwise leave full screen.
        if presentsPlayer, !wasInPiP, controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.dismiss(animated: true)
        }
        item = nil
        configureRemoteCommands()
        errorMessage = nil
        isLoading = false
        isPresented = false
        isInPiP = false
        pictureInPictureStarting = false
        // While the phone serves a Chromecast, its silent audio keeps the app running.
        if releasingAudioSession && !wasInPiP && cast?.isServing != true {
            // Deactivation can block briefly, so keep it off the main thread.
            DispatchQueue.global(qos: .utility).async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func resetItemState() {
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
        if let showObserver, let player = controller.player { player.removeTimeObserver(showObserver) }
        showObserver = nil
        sideControls?.removeFromSuperview()
        sideControls = nil
        cachedShow = nil
        subtitlesButton = nil
        showButton = nil
        sleepTimerButton = nil
        setSkipIntroVisible(false)
        reachedCredits = false
        skippedIntroAutomatically = false
        hideUpNext()
        askedAboutDeleting = false
        captionGroup = nil
        captionOptions = []
        forcedCaptionOption = nil
        captionNames = []
        selectedCaption = nil
        playbackEnded = false
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

    /// Returns whether closing counted as finishing: in the last 10%, usually the credits.
    @discardableResult
    private func savePosition(closing: Bool = false) -> Bool {
        guard !playbackEnded, let item, let seconds = controller.player?.currentTime().seconds else { return false }
        let finished = item.recordPosition(seconds, duration: item.duration ?? controller.player?.currentItem?.duration.seconds, closing: closing)
        try? context.save()
        return finished
    }

    private func didFinishPlayback(_ notification: Notification) {
        guard let current = controller.player?.currentItem, notification.object as? AVPlayerItem === current else { return }
        playbackEnded = true
        item?.setWatched(true)
        try? context.save()
        if sleepTimerOption == .endOfVideo { expireSleepTimer() }
        if let item { episodeFinished(item, atCredits: false) }
    }

    // MARK: Finished episodes

    private func episodeFinished(_ item: DownloadItem, atCredits: Bool) {
        guard sleepTimerTick() else { return }
        // Nothing can be shown in Picture in Picture or the background.
        let onScreen = presentsPlayer && !isInPiP && UIApplication.shared.applicationState == .active
        let next = sleepTimerOption == .endOfVideo ? nil : shows?.autoplayNext(after: item)
        var offer: DownloadItem?
        switch finishedEpisodeSetting(for: item) {
        case .delete:
            episodeToDelete = item
        case .ask where onScreen && !askedAboutDeleting:
            askedAboutDeleting = true
            offer = item
        default:
            break
        }
        // Off screen the next episode starts at the end; from the credits, the episode plays on to its end first.
        guard onScreen else {
            if let next, !atCredits { playNext(next) }
            return
        }
        if next != nil || offer != nil { showEndCard(next: next, offering: offer) }
    }

    /// Ask First asks once the player has gone, unless the end card already offered.
    private func closedFinished(_ episode: DownloadItem, presented: Bool) {
        switch finishedEpisodeSetting(for: episode) {
        case .delete:
            episodeToDelete = episode
        case .ask where !askedAboutDeleting:
            // The banner waits for the player to finish closing.
            if presented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finishedEpisode = episode }
            } else {
                finishedEpisode = episode
            }
        default:
            break
        }
    }

    private func finishedEpisodeSetting(for item: DownloadItem) -> FinishedEpisodes {
        item.showID == nil ? .keep : downloads?.finishedEpisodes ?? .keep
    }

    func answerFinishedEpisode(delete: Bool) {
        guard let episode = finishedEpisode else { return }
        finishedEpisode = nil
        if delete { deleteEpisode(episode) }
    }

    private func deleteFinishedEpisode() {
        guard let episode = episodeToDelete else { return }
        episodeToDelete = nil
        deleteEpisode(episode)
    }

    private func deleteEpisode(_ episode: DownloadItem) {
        // Already deleted elsewhere, such as from My Videos during Picture in Picture.
        guard episode.modelContext != nil, let downloads else { return }
        diagnostics.record(event: "storage", url: episode.localURL?.absoluteString ?? "app://player", note: "Deleted finished episode \(episode.displayTitle)")
        downloads.delete(episode)
    }

    // MARK: End card

    /// The tick box applies however the card goes, once the player has let go of the episode.
    private func showEndCard(next: DownloadItem?, offering episode: DownloadItem?) {
        hideUpNext()
        upNextItem = next
        cardEpisode = episode
        showPanel(makeEndCard(next: next, offering: episode))
        guard next != nil else { return }
        // Longer when there's a box to tick, so there's time to decide.
        upNextCountdown = LaunchOptions.upNextSeconds ?? (episode == nil ? 5 : 10)
        upNextTotal = upNextCountdown
        updateUpNextCountdown()
        animateFill()
        upNextTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickUpNext() }
        }
    }

    private func tickUpNext() {
        guard sleepTimerTick() else { return }
        upNextCountdown -= 1
        if upNextCountdown <= 0, let next = upNextItem { playNext(next) } else { updateUpNextCountdown(); animateFill() }
    }

    /// Short steps keep the app idle between them; UI tests snapshot an animating card without its buttons.
    private func animateFill() {
        guard let fill = upNextFill, let track = upNextButton?.superview, upNextTotal > 0 else { return }
        track.superview?.layoutIfNeeded()
        fill.constant = track.bounds.width * CGFloat(upNextTotal - upNextCountdown + 1) / CGFloat(upNextTotal)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) { track.layoutIfNeeded() }
    }

    private func updateUpNextCountdown() {
        upNextButton?.accessibilityValue = "Playing in \(upNextCountdown)"
    }

    /// Removes the end card, applying its tick box.
    private func hideUpNext() {
        if deleteTicked, let cardEpisode { episodeToDelete = cardEpisode }
        cardEpisode = nil
        deleteTicked = false
        deleteToggle = nil
        upNextTimer?.invalidate()
        upNextTimer = nil
        upNextPanel?.removeFromSuperview()
        upNextPanel = nil
        upNextButton = nil
        upNextFill = nil
        upNextItem = nil
    }

    private func showPanel(_ panel: UIView) {
        controller.view.addSubview(panel)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -32),
            panel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            // Clear of AVKit's scrubber and transport controls.
            panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -100)
        ])
        upNextPanel = panel
    }

    private func toggleDelete() {
        deleteTicked.toggle()
        guard let deleteToggle else { return }
        deleteToggle.configuration?.image = UIImage(systemName: deleteTicked ? "checkmark.square.fill" : "square")
        deleteToggle.accessibilityValue = deleteTicked ? "1" : "0"
    }

    private static func deleteToggleConfiguration(for episode: DownloadItem, ticked: Bool) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        let size = episode.fileSize.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        configuration.title = "Delete this episode\(size)"
        configuration.image = UIImage(systemName: ticked ? "checkmark.square.fill" : "square")
        configuration.imagePadding = 8
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        return configuration
    }

    private func makeEndCard(next: DownloadItem?, offering episode: DownloadItem?) -> UIView {
        let heading = UILabel()
        heading.text = next == nil ? "Finished" : "Up Next"
        heading.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
        heading.textColor = UIColor(white: 1, alpha: 0.7)
        let name = UILabel()
        name.text = (next ?? episode)?.displayTitle
        name.font = .preferredFont(forTextStyle: .headline)
        name.textColor = .white
        name.numberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.textAlignment = .right
        var rows: [UIView] = [heading, name]

        if let episode {
            let toggle = UIButton(configuration: Self.deleteToggleConfiguration(for: episode, ticked: deleteTicked),
                                  primaryAction: UIAction { [weak self] _ in self?.toggleDelete() })
            toggle.accessibilityIdentifier = "player.deleteEpisode.toggle"
            toggle.accessibilityValue = deleteTicked ? "1" : "0"
            deleteToggle = toggle
            rows.append(toggle)
        }

        let buttons: [UIView]
        if next != nil {
            let credits = Self.cardButton("Watch Credits", identifier: "player.upNext.cancel") { [weak self] in self?.hideUpNext() }
            buttons = [credits, makeNextEpisodeButton()]
        } else {
            buttons = [Self.cardButton("Done", identifier: "player.endCard.done", prominent: true) { [weak self] in self?.close() }]
        }
        let row = UIStackView(arrangedSubviews: buttons)
        row.spacing = 10
        rows.append(row)

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.spacing = 4
        stack.setCustomSpacing(10, after: rows[rows.count - 2])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.accessibilityIdentifier = "player.endCard"
        // Legible over bright frames without a box.
        for label in [heading, name] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 4
            label.layer.shadowOffset = .zero
        }
        return stack
    }

    private func makeNextEpisodeButton() -> UIView {
        let track = UIView()
        track.backgroundColor = UIColor(white: 0.62, alpha: 1)
        track.layer.cornerRadius = 6
        track.clipsToBounds = true
        let fill = UIView()
        fill.backgroundColor = .white
        fill.translatesAutoresizingMaskIntoConstraints = false
        let button = Self.cardButton("Next Episode", systemImage: "play.fill", identifier: "player.upNext.play", clear: true) { [weak self] in
            guard let self, let next = self.upNextItem else { return }
            self.playNext(next)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        track.addSubview(button)
        let width = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            width, fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor), fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: track.leadingAnchor), button.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            button.topAnchor.constraint(equalTo: track.topAnchor), button.bottomAnchor.constraint(equalTo: track.bottomAnchor)
        ])
        upNextButton = button
        upNextFill = width
        return track
    }

    private static func cardButton(_ title: String, systemImage: String? = nil, identifier: String, prominent: Bool = false,
                                   clear: Bool = false, action: @escaping @MainActor () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = systemImage.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 8
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .bold)
            return attributes
        }
        configuration.baseBackgroundColor = clear ? .clear : prominent ? .white : UIColor(white: 0.2, alpha: 0.85)
        configuration.baseForegroundColor = clear || prominent ? .black : .white
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = identifier
        return button
    }

    var isShowingUpNext: Bool { upNextItem != nil }

    /// AVKit's close button; Picture in Picture also ends full screen, but playback continues there.
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
        // The lock would cover the rest of the app, not the Picture in Picture window.
        unlockScreen()
        // The end card can't show in Picture in Picture: the next episode starts, and the tick box stands.
        if let next = upNextItem { playNext(next) } else { hideUpNext() }
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
