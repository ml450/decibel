import AppKit
import SwiftUI

/// The accent colour the user picked in Settings.
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, pink, magenta, orange, red, green, teal, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .blue: "Decibel blue"
        case .pink: "Pink"
        case .magenta: "Magenta"
        case .orange: "Orange"
        case .red: "Red"
        case .green: "Green"
        case .teal: "Teal"
        case .custom: "Custom"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .blue: Color(red: 0.30, green: 0.45, blue: 0.97)
        case .pink: Color(red: 1.00, green: 0.42, blue: 0.68)
        case .magenta: Color(red: 0.84, green: 0.28, blue: 0.86)
        case .orange: Color(red: 1.00, green: 0.58, blue: 0.10)
        case .red: Color(red: 0.96, green: 0.30, blue: 0.27)
        case .green: Color(red: 0.22, green: 0.76, blue: 0.40)
        case .teal: Color(red: 0.18, green: 0.68, blue: 0.80)
        case .custom: Appearance.shared.customColor
        }
    }
}

/// Holds the accent so every view that reads `Theme.accent` redraws when it changes (Observation tracks
/// the read, even through the static property).
@MainActor @Observable
final class Appearance {
    static let shared = Appearance()
    /// Off for `--snapshot`, which shares the installed app's settings.
    @ObservationIgnored var persists = true
    /// The menu bar item isn't SwiftUI; it redraws through this.
    @ObservationIgnored var onChange: (() -> Void)?

    var accent: AccentChoice = AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .blue {
        didSet { if persists { UserDefaults.standard.set(accent.rawValue, forKey: "accent") }; onChange?() }
    }

    /// The colour-wheel pick for `.custom`: hue around the wheel, saturation outwards; brightness stays high
    /// so the accent always reads well on the dark glass.
    var customHue: Double = UserDefaults.standard.object(forKey: "customHue") as? Double ?? 0.92 {
        didSet { if persists { UserDefaults.standard.set(customHue, forKey: "customHue") }; onChange?() }
    }
    var customSaturation: Double = UserDefaults.standard.object(forKey: "customSaturation") as? Double ?? 0.65 {
        didSet { if persists { UserDefaults.standard.set(customSaturation, forKey: "customSaturation") }; onChange?() }
    }

    var customColor: Color { Color(hue: customHue, saturation: customSaturation, brightness: 0.96) }
}

@MainActor
enum Theme {

    /// Accent colour, chosen in Settings (default: Health app "Hearing" blue).
    static var accent: Color { Appearance.shared.accent.color }
    /// "Too loud" stays distinguishable from the accent, even when the accent is orange.
    static var loud: Color { Appearance.shared.accent == .orange ? .red : .orange }

    /// Cards sit on the popover's material, so they are a translucent lift rather than an opaque fill.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.75)
    })

    /// "Fine" levels: classic green with the default Decibel blue, otherwise the chosen accent.
    static var safe: Color { Appearance.shared.accent == .blue ? .green : accent }

    /// Under 80 dB the level is `safe`; 80–90 is a yellow warning; over 90 red
    /// (purple when the accent itself is red, so the two never blur).
    static func levelColor(_ db: Double) -> Color {
        db < 80 ? safe : db <= 90 ? .yellow : (Appearance.shared.accent == .red ? .purple : .red)
    }

    static func levelNSColor(_ db: Double) -> NSColor {
        db < 80 ? (Appearance.shared.accent == .blue ? .systemGreen : NSColor(accent))
            : db <= 90 ? .systemYellow : (Appearance.shared.accent == .red ? .systemPurple : .systemRed)
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        if seconds <= 0 { return "0 min" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "–"
    }

    static func db(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "–"
    }

    static func rangeLabel(_ range: TimeRange, _ interval: DateInterval) -> String {
        if range == .day { return "Today" }
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: interval.start, to: interval.end.addingTimeInterval(-1))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A card with a small grey heading, as used by Settings and Calibrate.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct CardTitle: View {
    let title: String
    let symbol: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Spacer()
            if let trailing {
                Text(trailing).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct BigValue: View {
    let value: String
    let unit: String
    var color: Color = .primary
    var size: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

struct DeviceIcon: View {
    let symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Thin 4 pt slider used for volume and track progress. A small glossy knob appears on hover and while
/// dragging (as in Spotify and macOS); it grows in place, and only its appearance is animated.
struct ThinSlider: View {
    let value: Double                         // 0…1
    var onChange: ((Double) -> Void)? = nil   // live, while dragging
    var onEnd: ((Double) -> Void)? = nil      // when released

    @State private var drag: Double?
    @State private var hovering = false

    var body: some View {
        let fraction = min(1, max(0, drag ?? value))
        let pressed = drag != nil || hovering
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: fraction > 0 ? max(4, geo.size.width * fraction) : 0)
            }
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(width: 11, height: 11)
                    .scaleEffect(pressed ? 1 : 0.4)
                    .opacity(pressed ? 1 : 0)
                    .animation(.smooth(duration: 0.15), value: pressed)
                    .offset(x: geo.size.width * fraction - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let x = min(1, max(0, Double(g.location.x / geo.size.width)))
                        drag = x
                        onChange?(x)
                    }
                    .onEnded { g in
                        onEnd?(min(1, max(0, Double(g.location.x / geo.size.width))))
                        drag = nil
                    }
            )
        }
        .frame(height: 12)
    }
}
