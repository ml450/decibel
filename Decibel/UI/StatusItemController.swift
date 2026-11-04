import AppKit
import QuartzCore

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
    private var keepBox = false

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
    /// `keepBox`: a short silence while sound is on (between songs). The number fades, but the box keeps
    /// its width; it only shrinks to the ear when muted or nothing plays.
    func update(text: String?, color: NSColor, toolTip: String, keepBox: Bool = false) {
        item.button?.toolTip = toolTip
        self.keepBox = keepBox
        guard let text else {
            if visible {
                reveal(false)
            } else if !keepBox, !holdWidth, tween == nil, item.length > iconWidth + 0.5 {
                animate(revealTo: 0, lengthTo: iconWidth, duration: 0.24, easeOut: false)
            }
            return
        }
        let widthChanged = max(2, text.count) != max(2, label.stringValue.count)
        label.stringValue = text
        label.textColor = color
        if !visible {
            reveal(true)
        } else if widthChanged {
            // 9 → 10: glide to the new width instead of jumping.
            animate(revealTo: 1, lengthTo: holdWidth ? max(item.length, expandedLength) : expandedLength,
                    duration: 0.18, easeOut: true)
        }
    }

    /// Room for two digits at least, so 1 dB and 22 dB get the same box; only 100+ widens it.
    private var numberWidth: CGFloat {
        let two = ("88" as NSString).size(withAttributes: [.font: label.font as Any]).width
        return ceil(max(two, label.intrinsicContentSize.width))
    }

    private var expandedLength: CGFloat { iconWidth + numberWidth + 2 }

    /// 0 = only the ear, 1 = number fully shown.
    private var revealed: CGFloat = 0

    private var scale: CGFloat { item.button?.window?.backingScaleFactor ?? 2 }
    /// Whole device pixels, so the ear and number never sit between pixels mid-animation (that shimmer
    /// read as stutter).
    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    /// Right-aligned against the ear; `offset` > 0 tucks it towards (behind) the ear.
    private func layoutLabel(offset: CGFloat) {
        guard let button = item.button else { return }
        let size = label.intrinsicContentSize
        let width = ceil(size.width) + 2
        label.frame = NSRect(x: snap(button.bounds.width - iconWidth + 2 - width + offset),
                             y: snap((button.bounds.height - size.height) / 2), width: width, height: size.height)
    }

    /// One tween drives the item width, the number's slide and its fade together, so they stay in step.
    /// NSStatusItem.length isn't animatable, hence the manual tween.
    private func reveal(_ show: Bool) {
        visible = show
        // While the panel is open the item keeps its width: macOS re-centres status items when they
        // resize, which made the ear jump on mute/unmute. The number just fades in and out in place.
        animate(revealTo: show ? 1 : 0,
                lengthTo: show ? expandedLength : (holdWidth || keepBox ? item.length : iconWidth),
                duration: show ? 0.3 : 0.24, easeOut: show)
    }

    private var tween: (begin: CFTimeInterval, duration: Double, easeOut: Bool,
                        reveal: (CGFloat, CGFloat), length: (CGFloat, CGFloat))?
    private var displayLink: CADisplayLink?

    private func animate(revealTo: CGFloat, lengthTo: CGFloat, duration: Double, easeOut: Bool) {
        tween = (CACurrentMediaTime(), duration, easeOut, (revealed, revealTo), (item.length, lengthTo))
        if displayLink == nil, let button = item.button {
            // Ticks in step with the display's refresh, unlike a Timer, so frames are evenly spaced.
            let link = button.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        step()
    }

    @objc private func step() {
        guard let tw = tween else { return }
        let t = min(1, (CACurrentMediaTime() - tw.begin) / tw.duration)
        // Smooth ease (cubic) both ways; ease-out when appearing, ease-in-out when leaving.
        let eased = CGFloat(tw.easeOut ? 1 - pow(1 - t, 3) : (t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2))
        revealed = tw.reveal.0 + (tw.reveal.1 - tw.reveal.0) * eased
        let length = snap(tw.length.0 + (tw.length.1 - tw.length.0) * eased)
        if abs(length - item.length) > 0.01 {
            item.length = length
            onResize?()
        }
        label.alphaValue = revealed
        layoutLabel(offset: slide * (1 - revealed))
        if t >= 1 {
            tween = nil
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Set while the panel is open; releasing it shrinks the item if the number is gone.
    var holdWidth = false {
        didSet {
            guard !holdWidth, !visible, !keepBox, item.length > iconWidth + 0.5 else { return }
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
