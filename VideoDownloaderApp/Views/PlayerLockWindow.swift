import UIKit

/// Takes every touch so water in the shower or a pocket can't pause, seek or close the video.
final class PlayerLockWindow: UIWindow {
    private weak var previousKey: UIWindow?

    init(scene: UIWindowScene, unlock: @escaping () -> Void) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        super.init(windowScene: scene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        rootViewController = PlayerLockViewController(unlock: unlock)
        // Key, so iOS asks this window about the status bar, home indicator and edge swipes.
        makeKeyAndVisible()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func remove() {
        isHidden = true
        previousKey?.makeKey()
    }
}

private final class PlayerLockViewController: UIViewController {
    private let unlock: () -> Void
    private let lockButton = UIButton(configuration: .filled())
    private var armed = false
    private var fade: Task<Void, Never>?

    init(unlock: @escaping () -> Void) {
        self.unlock = unlock
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // Going home or opening Control Center takes a second swipe while locked.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.locked"
        // VoiceOver stays on the lock instead of the player's controls underneath.
        view.accessibilityViewIsModal = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showLock)))

        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.8)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        lockButton.configuration = configuration
        lockButton.accessibilityIdentifier = "player.unlock"
        lockButton.addAction(UIAction { [weak self] _ in self?.lockTapped() }, for: .primaryActionTriggered)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lockButton)
        NSLayoutConstraint.activate([
            lockButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lockButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])
        show(armed: false)
    }

    @objc private func showLock() { show(armed: false) }

    private func lockTapped() {
        if armed { unlock() } else { show(armed: true) }
    }

    private func show(armed: Bool) {
        self.armed = armed
        var configuration = lockButton.configuration
        configuration?.image = UIImage(systemName: armed ? "lock.open.fill" : "lock.fill")
        configuration?.title = armed ? "Tap Again to Unlock" : "Screen Locked"
        configuration?.subtitle = armed ? nil : "Tap to unlock"
        lockButton.configuration = configuration
        UIView.animate(withDuration: 0.2) { self.lockButton.alpha = 1 }
        fade?.cancel()
        fade = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            // VoiceOver can't find a hidden button, so it stays for VoiceOver users.
            guard let self, !Task.isCancelled, !UIAccessibility.isVoiceOverRunning else { return }
            self.armed = false
            UIView.animate(withDuration: 0.3) { self.lockButton.alpha = 0 }
        }
    }
}
