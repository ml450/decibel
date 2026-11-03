import SwiftUI

/// "Hearing | Loudness" at the top of the panel.
struct PanelTabs: View {
    @Environment(AppModel.self) private var model
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            tab("Hearing", symbol: "ear", page: .home)
            tab("Loudness", symbol: "waveform", page: .loudness, live: model.loudnessRunning)
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func tab(_ title: String, symbol: String, page: PanelPage, live: Bool = false) -> some View {
        let selected = model.page == page
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title)
            if live && !selected {
                Circle().fill(.red).frame(width: 6, height: 6)   // measuring in the background
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(selected ? Color.white : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            if selected { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: pill) }
        }
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { model.page = page } }
    }
}

/// LUFS meter in the style of a mixer's loudness panel: M, S and TP bars plus the key numbers.
struct LoudnessTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let r = model.loudness
        let target = model.loudnessTarget

        VStack(alignment: .leading, spacing: 10) {
            Picker("Target", selection: $model.loudnessTarget) {
                ForEach(LoudnessTarget.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Card {
                HStack(alignment: .top, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        MeterScale(target: target.lufs)
                        MeterBar(label: "M", value: r?.momentary, target: target.lufs)
                        MeterBar(label: "S", value: r?.shortTerm, target: target.lufs)
                        MeterBar(label: "TP", value: r?.truePeak, target: nil, ceiling: -1)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .leading, spacing: 9) {
                        stat("Short", r?.shortTerm)
                        stat("Short Max", r?.shortTermMax)
                        stat("Range (LU)", r?.range)
                        stat("True Peak", r?.truePeak, warn: (r?.truePeak ?? -100) > -1)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Integrated").font(.caption).foregroundStyle(.secondary)
                            Text(r?.integrated.map(Self.number) ?? "–")
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(r?.integrated.map { Self.color($0 - target.lufs) } ?? .primary)
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(width: 92, alignment: .leading)
                }
                Text(verdict(r, target))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button {
                    model.loudnessRunning ? model.stopLoudness() : model.startLoudness()
                } label: {
                    Label(model.loudnessRunning ? "Pause" : (r == nil ? "Start" : "Resume"),
                          systemImage: model.loudnessRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    model.resetLoudness()
                } label: {
                    Text("Reset").frame(maxWidth: .infinity)
                }
                .disabled(r == nil)
            }
            .controlSize(.large)

            Text("Press Start and play your video from the beginning. Decibel measures everything your Mac plays, so mute other apps meanwhile.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func stat(_ title: String, _ value: Double?, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(Self.number) ?? "–")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(warn ? Theme.loud : Theme.accent)
        }
    }

    private func verdict(_ r: LoudnessReading?, _ target: LoudnessTarget) -> String {
        guard let r else { return "Not measured yet." }
        guard let integrated = r.integrated else {
            return model.loudnessRunning ? "Listening… values appear after a few seconds of sound." : "No sound measured."
        }
        let diff = integrated - target.lufs
        let time = " (\(Self.duration(r.seconds)))"
        if abs(diff) < 1 { return "On target for \(target.name)." + time }
        let amount = String(format: "%.1f", abs(diff))
        let goal = Self.number(target.lufs).replacingOccurrences(of: ".0", with: "")
        return (diff > 0
            ? "\(amount) LU louder than \(goal) LUFS. \(target.name) will turn it down."
            : "\(amount) LU quieter than \(goal) LUFS.") + time
    }

    /// Green within ±1 LU of the target, yellow within ±2, orange beyond.
    static func color(_ diff: Double) -> Color {
        abs(diff) < 1 ? .green : abs(diff) < 2 ? .yellow : Theme.loud
    }

    static func number(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shared scale for the meter bars: −60 to 0.
private enum Meter {
    static let range: ClosedRange<Double> = -60...0
    static let height: CGFloat = 196
    static let labelHeight: CGFloat = 16

    static func y(_ value: Double) -> CGFloat {
        let v = min(max(value, range.lowerBound), range.upperBound)
        return height * CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

private struct MeterScale: View {
    let target: Double

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 22, height: Meter.labelHeight)
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                ForEach([0, -10, -20, -30, -40, -50, -60] + [target], id: \.self) { v in
                    Text(LoudnessTab.number(v).replacingOccurrences(of: ".0", with: ""))
                        .font(.system(size: 9, weight: v == target ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(v == target ? Color.primary : Color.secondary)
                        .offset(y: -Meter.y(v) + 5)
                }
            }
            .frame(width: 22, height: Meter.height)
        }
    }
}

/// One vertical bar. LUFS bars colour by distance to the target; the TP bar warns above its ceiling.
private struct MeterBar: View {
    let label: String
    let value: Double?
    let target: Double?
    var ceiling: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: Meter.labelHeight, alignment: .top)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(height: value.map(Meter.y) ?? 0)
                    .animation(.linear(duration: 0.1), value: value)
                if let target {
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(height: 1)
                        .offset(y: -Meter.y(target))
                }
            }
            .frame(width: 16, height: Meter.height)
        }
    }

    private var color: Color {
        guard let value else { return Theme.accent }
        if let ceiling { return value > ceiling ? Theme.loud : Theme.accent }
        guard let target else { return Theme.accent }
        return value > target + 1 ? Theme.loud : value >= target - 1 ? .green : Theme.accent
    }
}
