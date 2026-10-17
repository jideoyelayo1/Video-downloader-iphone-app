import AVFoundation
import AVKit
import MediaPlayer
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
    /// A finished episode to ask about deleting once the player has closed.
    @Published private(set) var finishedEpisode: DownloadItem?

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
    /// Whether "no captions" keeps the forced-only track, as the viewer last left it.
    private var offKeepsForced = true
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
    /// Episode menu for videos in a show: next/previous, intro and credits marks.
    private var showButton: UIButton?
    /// The column of buttons beside AVKit's controls, which shows and fades with them.
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
    /// AVKit applies its own subtitle preference just after it takes over a new player, which
    /// would undo the viewer's remembered choice. Changes in this window are reverted.
    private var automaticSelectionWindowEnd = Date.distantPast
    private var automaticSelectionReverts = 0
    /// Plays on to the next episode of a show that has autoplay on.
    var shows: ShowStore?
    private var upNextItem: DownloadItem?
    private var upNextPanel: UIView?
    private var upNextButton: UIButton?
    /// The white fill that sweeps across Next Episode as it counts down.
    private var upNextFill: NSLayoutConstraint?
    private var upNextTimer: Timer?
    private var upNextCountdown = 0
    private var upNextTotal = 0
    /// Deletes finished episodes, as the Delete Finished Episodes setting asks.
    var downloads: DownloadManager?
    /// A finished episode, deleted once the player has let go of it.
    private var episodeToDelete: DownloadItem?
    /// The finished episode the end card offers to delete, and whether its box is ticked.
    private var cardEpisode: DownloadItem?
    private var deleteTicked = false
    private var deleteToggle: UIButton?
    /// Each episode is asked about once.
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
        // The next video activates the session again right away. A finished episode opened again stays.
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
        guard let player = controller.player, let url = next.localURL, FileManager.default.fileExists(atPath: url.path) else { return }
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

    /// Loads a saved video into a new player, or into `existing` for the next episode.
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
        playerItem.externalMetadata = [Self.titleMetadata(newItem.displayTitle)]
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
                // iOS 26 keeps re-applying the system's subtitle preference over the viewer's
                // remembered choice; its AVKit Off works without automatic criteria. iOS 18's
                // AVKit needs them for its own Off, so they stay on there.
                player.appliesMediaSelectionCriteriaAutomatically = false
            }
            controller.player = player
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
            Task { @MainActor [weak self] in self?.savePosition() }
        }
        isLoading = false
        if position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) { _ in player.play() }
        } else { player.play() }
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

    /// Selects an embedded track through AVFoundation, or draws a site subtitle file over the video.
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
        // A forced-only track counts as captions off (it is AVKit's Off on iOS 26).
        let index = selected.flatMap { captionOptions.firstIndex(of: $0) }
        let forcedSelected = selected.map(Self.isForcedOnly) ?? false
        let showingSite = selectedCaption.map { $0 >= captionOptions.count } ?? false
        // The notification also arrives, later, for the app's own selections: only a selection
        // that differs from the app's state is the viewer's. With a site subtitle showing, the
        // embedded selection is off.
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

    /// Buttons AVKit has no place for, in a column beside its controls that appears and fades
    /// with them: Subtitles for site subtitle files AVKit can't list, and an episode menu for
    /// videos in a show.
    private func installSideControls() {
        guard sideControls == nil else { return }
        var buttons: [UIButton] = []
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
        guard !buttons.isEmpty else { return }
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
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.72)
            configuration.cornerStyle = .capsule
        }
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
        let target: CGFloat = avkitControlsVisible() == false ? 0 : 1
        guard sideControls.alpha != target else { return }
        UIView.animate(withDuration: 0.25) { sideControls.alpha = target }
    }

    // MARK: Shows: episodes, intro and credits, speed

    /// The show of the video playing. Read twice a second during playback, so it's looked up
    /// once per video rather than fetching every show each time.
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

    /// Skip Intro, the start of the credits, and the speed chosen for the show.
    private func observeShowPlayback(of player: AVPlayer) {
        reachedCredits = false
        skippedIntroAutomatically = false
        guard currentShow != nil else { return }
        showObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.showPlaybackTick(at: time.seconds) }
        }
    }

    /// Checked twice a second while an episode of a show plays.
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

    /// AVKit's speed menu sets `selectedSpeed`; the show keeps the last one chosen.
    private func rememberShowSpeed(_ show: Show) {
        guard let rate = controller.selectedSpeed?.rate else { return }
        let stored: Double? = abs(rate - 1) < 0.01 ? nil : Double(rate)
        guard stored != show.playbackRate else { return }
        show.playbackRate = stored
        shows?.save()
    }

    private func applyShowSpeed() {
        guard let rate = currentShow?.playbackRate,
              let speed = controller.speeds.first(where: { abs(Double($0.rate) - rate) < 0.01 }) else { return }
        controller.selectSpeed(speed)
    }

    /// Next and previous episode from the Lock Screen and Control Center.
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

    /// Plays the next (1) or previous (-1) episode of the current show in the same player.
    @discardableResult
    func playEpisode(_ offset: Int) -> Bool {
        guard let item, let episode = shows?.episode(offset, from: item) else { return false }
        playNext(episode)
        return true
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

    /// - Parameters:
    ///   - releasingAudioSession: lets music or podcasts paused by playback resume.
    ///   - kept: a video about to be opened again, so it isn't deleted as a finished episode.
    func close(releasingAudioSession: Bool = true, keeping kept: DownloadItem? = nil) {
        let wasInPiP = isInPiP
        let presented = presentsPlayer && controller.presentingViewController != nil
        loadID = UUID()
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
        if releasingAudioSession && !wasInPiP {
            // Deactivation can block briefly, so keep it off the main thread.
            DispatchQueue.global(qos: .utility).async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Everything tied to the current video, cleared on close and before the next episode.
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

    /// Closing in the last 10% (usually the credits) counts as watching to the end.
    /// - Returns: whether closing counted as finishing the video.
    @discardableResult
    private func savePosition(closing: Bool = false) -> Bool {
        guard !playbackEnded, let item,
              let seconds = controller.player?.currentTime().seconds,
              seconds.isFinite, seconds > 0 else { return false }
        let finished = closing && WatchProgress.isFinished(position: seconds, duration: item.duration ?? controller.player?.currentItem?.duration.seconds)
        if finished {
            item.setWatched(true)
        } else {
            item.playbackPosition = seconds
        }
        try? context.save()
        return finished
    }

    private func didFinishPlayback(_ notification: Notification) {
        guard let current = controller.player?.currentItem, notification.object as? AVPlayerItem === current else { return }
        playbackEnded = true
        item?.setWatched(true)
        try? context.save()
        if let item { episodeFinished(item, atCredits: false) }
    }

    // MARK: Finished episodes

    /// The end of an episode, or the start of its marked credits. The Delete Finished Episodes
    /// setting deletes it, or (Ask First) puts a tick box on the end card beside Next Episode.
    private func episodeFinished(_ item: DownloadItem, atCredits: Bool) {
        // Nothing can be shown in Picture in Picture or the background.
        let onScreen = presentsPlayer && !isInPiP && UIApplication.shared.applicationState == .active
        let next = shows?.autoplayNext(after: item)
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
        // Off screen, the next episode starts at once at the end; from the credits, the episode
        // plays on to its end first.
        guard onScreen else {
            if let next, !atCredits { playNext(next) }
            return
        }
        if next != nil || offer != nil { showEndCard(next: next, offering: offer) }
    }

    /// An episode closed once watched. Ask First asks once the player has gone, unless the end card offered already.
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

    /// The setting applies to episodes of shows.
    private func finishedEpisodeSetting(for item: DownloadItem) -> FinishedEpisodes {
        item.showID == nil ? .keep : downloads?.finishedEpisodes ?? .keep
    }

    /// The answer to the banner shown after the player closed.
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

    /// Netflix-style: Watch Credits and a Next Episode button that fills as it counts down, and
    /// with Ask First a tick box to delete the finished episode. The box's state is applied
    /// however the card goes (Next Episode, the countdown, Watch Credits, Done or closing),
    /// once the player has let go of the episode.
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
        upNextCountdown -= 1
        if upNextCountdown <= 0, let next = upNextItem { playNext(next) } else { updateUpNextCountdown(); animateFill() }
    }

    /// Moves the fill to the next second's mark. Short steps rather than one long animation, so
    /// the app is idle in between (UI tests snapshot an animating card without its buttons).
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

    /// Grey, with a white fill growing behind the black title as the countdown runs.
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

    /// Whether the countdown for the next episode is showing.
    var isShowingUpNext: Bool { upNextItem != nil }

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
