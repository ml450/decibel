import AppKit

/// Menu bar item: just the ear while it's quiet; the level fades and slides in beside it when sound plays.
/// The ear and number are our own subviews so the width and text can be animated.
@MainActor
final class StatusItemController {
    let item: NSStatusItem

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
        icon.frame = NSRect(x: 0, y: 0, width: iconWidth, height: button.bounds.height)
        icon.autoresizingMask = [.height]
        button.addSubview(icon)

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.alphaValue = 0
        button.addSubview(label)
    }

    /// `text` nil = quiet (only the ear is shown).
    func update(text: String?, color: NSColor, toolTip: String) {
        item.button?.toolTip = toolTip
        guard let text else {
            if visible { hide() }
            return
        }
        let widthChanged = text.count != label.stringValue.count
        label.stringValue = text
        label.textColor = color
        if !visible {
            show()
        } else if widthChanged {
            layoutLabel(offset: 0)
            animateLength(to: expandedLength, duration: 0.15)
        }
    }

    private var expandedLength: CGFloat { iconWidth + ceil(label.intrinsicContentSize.width) + 4 }

    private func layoutLabel(offset: CGFloat) {
        guard let button = item.button else { return }
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: iconWidth - 4 + offset, y: (button.bounds.height - size.height) / 2,
                             width: ceil(size.width) + 2, height: size.height)
    }

    private func show() {
        visible = true
        layoutLabel(offset: -slide)
        animateLength(to: expandedLength, duration: 0.25)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = 1
            label.animator().setFrameOrigin(NSPoint(x: iconWidth - 4, y: label.frame.origin.y))
        }
    }

    private func hide() {
        visible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            label.animator().alphaValue = 0
            label.animator().setFrameOrigin(NSPoint(x: iconWidth - 4 - slide, y: label.frame.origin.y))
        }
        animateLength(to: iconWidth, duration: 0.25, delay: 0.1)
    }

    /// NSStatusItem.length isn't animatable, so tween it by hand.
    private func animateLength(to target: CGFloat, duration: TimeInterval, delay: TimeInterval = 0) {
        lengthTimer?.invalidate()
        let start = item.length
        guard abs(start - target) > 0.5 else { item.length = target; return }
        let begin = Date().addingTimeInterval(delay)
        lengthTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, max(0, Date().timeIntervalSince(begin) / duration))
                let eased = 1 - pow(1 - t, 3)   // ease-out cubic
                self.item.length = start + (target - start) * eased
                if t >= 1 { timer.invalidate() }
            }
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
