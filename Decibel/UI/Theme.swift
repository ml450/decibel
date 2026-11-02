import AppKit
import SwiftUI

enum Theme {
    /// Accent colour (Health app "Hearing" blue).
    static let accent = Color(red: 0.30, green: 0.45, blue: 0.97)
    static let loud = Color.orange

    /// Cards sit on the popover's material, so they are a translucent lift rather than an opaque fill.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.75)
    })

    static func levelColor(_ db: Double) -> Color {
        db < 80 ? .green : db <= 90 ? .yellow : .red
    }

    static func levelNSColor(_ db: Double) -> NSColor {
        db < 80 ? .systemGreen : db <= 90 ? .systemYellow : .systemRed
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
