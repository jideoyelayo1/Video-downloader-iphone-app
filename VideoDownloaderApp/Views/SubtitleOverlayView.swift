import UIKit

/// Draws site subtitles over a saved video. AVFoundation can't attach a separate WebVTT file
/// to a downloaded movie or HLS package, so the player shows these cues itself. Installed in
/// `AVPlayerViewController.contentOverlayView`, between the video and the playback controls.
final class SubtitleOverlayView: UIView {
    private let bubble = UIView()
    private let label = UILabel()

    /// The video's rectangle inside this view, so text sits on the picture rather than the letterbox.
    var videoFrame: CGRect = .zero { didSet { if videoFrame != oldValue { setNeedsLayout() } } }

    var text: String? {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            bubble.isHidden = text == nil
            label.accessibilityLabel = text
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        bubble.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        bubble.layer.cornerRadius = 8
        bubble.layer.cornerCurve = .continuous
        bubble.isHidden = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "player.subtitle"
        label.accessibilityTraits = .staticText
        bubble.addSubview(label)
        addSubview(bubble)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bubble.isHidden else { return }
        let area = videoFrame.isEmpty ? bounds : videoFrame.intersection(bounds)
        let padding = UIEdgeInsets(top: 4, left: 10, bottom: 5, right: 10)
        let maxWidth = max(area.width - 32, 80)
        let fitted = label.sizeThatFits(CGSize(width: maxWidth - padding.left - padding.right, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(fitted.width, maxWidth - padding.left - padding.right) + padding.left + padding.right,
                          height: fitted.height + padding.top + padding.bottom)
        // Keep clear of the bottom edge, where the playback controls sit.
        let bottom = area.maxY - max(area.height * 0.06, 12)
        bubble.frame = CGRect(x: area.midX - size.width / 2, y: bottom - size.height, width: size.width, height: size.height).integral
        label.frame = bubble.bounds.inset(by: padding)
    }
}
