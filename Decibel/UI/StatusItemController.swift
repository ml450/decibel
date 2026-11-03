import AppKit

/// Menu bar item: just the ear while it's quiet; the level fades and slides out to the left of it when
/// sound plays. Status items grow to the left, so keeping the ear on the right means it never moves.
/// The ear and number are our own subviews so the width and text can be animated.
@MainActor
final class StatusItemController {
    let item: NSStatusItem
    /// Called whenever the item's width changes, so an open panel can stay anchored to the ear.
    var onResize: (() -> Void)?

    /// The ear, in the button's coordinates. It never moves on screen (the item grows to the left),
    /// so anchoring the panel here keeps it still while the number comes and goes.
    var earRect: NSRect {
        guard let button = item.button else { return .zero }
        return NSRect(x: button.bounds.width - iconWidth, y: 0, width: iconWidth, height: button.bounds.height)
    }

    private let icon = PassthroughImageView()
    private let label = PassthroughLabel(labelWithString: "")
    private let iconWidth: CGFloat = 28
    private let slide: CGFloat = 8
    private var visible = false
    private var lengthTimer: Timer?

    init() {
        item = NSStatusBar.system.statusItem(withLength: iconWidth)
        guard let button = item.button else { return }
        button.setAccessibilityLabel("Decibel")

        let image = NSImage(systemSymbolName: "ear", accessibilityDescription: "Decibel")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        icon.image = image
        icon.imageScaling = .scaleNone
        icon.frame = NSRect(x: button.bounds.width - iconWidth, y: 0, width: iconWidth, height: button.bounds.height)
        icon.autoresizingMask = [.height, .minXMargin]   // pinned to the right edge
        button.addSubview(icon)

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.alphaValue = 0
        label.autoresizingMask = [.minXMargin]              // stays next to the ear as the item widens
        button.addSubview(label)
    }

    /// `text` nil = quiet (only the ear is shown).
    func update(text: String?, color: NSColor, toolTip: String) {
        item.button?.toolTip = toolTip
        guard let text else {
            if visible { reveal(false) }
            return
        }
        let widthChanged = text.count != label.stringValue.count
        label.stringValue = text
        label.textColor = color
        if !visible {
            reveal(true)
        } else if widthChanged {
            item.length = expandedLength
            layoutLabel(offset: 0)
            onResize?()
        }
    }

    private var expandedLength: CGFloat { iconWidth + ceil(label.intrinsicContentSize.width) + 2 }

    /// 0 = only the ear, 1 = number fully shown.
    private var revealed: CGFloat = 0

    /// Right-aligned against the ear; `offset` > 0 tucks it towards (behind) the ear.
    private func layoutLabel(offset: CGFloat) {
        guard let button = item.button else { return }
        let size = label.intrinsicContentSize
        let width = ceil(size.width) + 2
        label.frame = NSRect(x: button.bounds.width - iconWidth + 2 - width + offset,
                             y: (button.bounds.height - size.height) / 2, width: width, height: size.height)
    }

    /// One timer drives the item width, the number's slide and its fade together, so they stay in step.
    /// NSStatusItem.length isn't animatable, hence the manual tween.
    private func reveal(_ show: Bool) {
        visible = show
        lengthTimer?.invalidate()
        let from = revealed, to: CGFloat = show ? 1 : 0
        // While the panel is open the item keeps its width: macOS re-centres status items when they
        // resize, which made the ear jump on mute/unmute. The number just fades in and out in place.
        let lengthFrom = item.length
        let lengthTo = show ? expandedLength : (holdWidth ? item.length : iconWidth)
        let duration = show ? 0.28 : 0.22
        let begin = Date()
        lengthTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(begin) / duration)
                let eased = CGFloat(show ? 1 - pow(1 - t, 3) : t * t * t)   // ease-out in, ease-in out
                self.revealed = from + (to - from) * eased
                self.item.length = lengthFrom + (lengthTo - lengthFrom) * eased
                self.label.alphaValue = self.revealed
                self.layoutLabel(offset: self.slide * (1 - self.revealed))
                self.onResize?()
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    /// Set while the panel is open; releasing it shrinks the item if the number is gone.
    var holdWidth = false {
        didSet {
            guard !holdWidth, !visible, item.length > iconWidth + 0.5 else { return }
            reveal(false)
        }
    }
}

/// Subviews must not swallow clicks meant for the status item button.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
