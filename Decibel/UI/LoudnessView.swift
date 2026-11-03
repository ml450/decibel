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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
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
    @State private var addingCustom = false

    var body: some View {
        let r = model.loudness
        let target = model.loudnessTarget
        let goal = model.targetLUFS

        VStack(alignment: .leading, spacing: 10) {
            TargetMenu(addingCustom: $addingCustom)
            if addingCustom {
                CustomTargetRow(isPresented: $addingCustom)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Card {
                HStack(alignment: .top, spacing: 0) {
                    // The bars take whatever height the tab has to spare.
                    GeometryReader { geo in
                        let barHeight = max(120, geo.size.height - Meter.labelHeight)
                        HStack(alignment: .top, spacing: 12) {
                            MeterScale(target: goal, height: barHeight)
                            MeterBar(label: "M", value: r?.momentary, target: goal, height: barHeight)
                            MeterBar(label: "S", value: r?.shortTerm, target: goal, height: barHeight)
                            MeterBar(label: "TP", value: r?.truePeak, target: nil, ceiling: -1, height: barHeight)
                        }
                    }
                    .frame(width: 22 + 3 * 16 + 3 * 12)
                    .frame(minHeight: 212)
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
                                .foregroundStyle(r?.integrated.map { Self.color($0 - goal) } ?? .primary)
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(width: 92, alignment: .leading)
                }
                Text(verdict(r, target, goal))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(maxHeight: .infinity)

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

    private func verdict(_ r: LoudnessReading?, _ target: LoudnessTarget, _ goal: Double) -> String {
        guard let r else { return "Not measured yet." }
        guard let integrated = r.integrated else {
            return model.loudnessRunning ? "Listening… values appear after a few seconds of sound." : "No sound measured."
        }
        let diff = integrated - goal
        let time = " (\(Self.duration(r.seconds)))"
        if abs(diff) < 1 { return "On target." + time }
        let amount = String(format: "%.1f", abs(diff))
        let goalText = Self.number(goal).replacingOccurrences(of: ".0", with: "")
        return (diff > 0
            ? "\(amount) LU louder than \(goalText) LUFS.\(target.tooLoudNote)"
            : "\(amount) LU quieter than \(goalText) LUFS.") + time
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
enum Meter {
    static let range: ClosedRange<Double> = -60...0
    static let labelHeight: CGFloat = 16

    static func y(_ value: Double, _ height: CGFloat) -> CGFloat {
        let v = min(max(value, range.lowerBound), range.upperBound)
        return height * CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

private struct MeterScale: View {
    let target: Double
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 22, height: Meter.labelHeight)
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                ForEach([0, -10, -20, -30, -40, -50, -60] + [target], id: \.self) { v in
                    Text(LoudnessTarget.format(v))
                        .font(.system(size: 9, weight: v == target ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(v == target ? Color.primary : Color.secondary)
                        .offset(y: -Meter.y(v, height) + 5)
                }
            }
            .frame(width: 22, height: height)
        }
    }
}

/// One vertical bar. LUFS bars colour by distance to the target; the TP bar warns above its ceiling.
private struct MeterBar: View {
    let label: String
    let value: Double?
    let target: Double?
    var ceiling: Double? = nil
    let height: CGFloat

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
                    .frame(height: value.map { Meter.y($0, height) } ?? 0)
                    .animation(.linear(duration: 0.1), value: value)
                if let target {
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(height: 1)
                        .offset(y: -Meter.y(target, height))
                }
            }
            .frame(width: 16, height: height)
        }
    }

    private var color: Color {
        guard let value else { return Theme.accent }
        if let ceiling { return value > ceiling ? Theme.loud : Theme.accent }
        guard let target else { return Theme.accent }
        return value > target + 1 ? Theme.loud : value >= target - 1 ? .green : Theme.accent
    }
}

/// Target picker with saved custom targets: add them with a value, remove them from a submenu.
private struct TargetMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var addingCustom: Bool

    var body: some View {
        Menu {
            ForEach(LoudnessTarget.builtIn, id: \.self) { option($0) }
            if !model.customTargets.isEmpty {
                Divider()
                ForEach(model.customTargets, id: \.self) { option(.custom($0)) }
            }
            Divider()
            Button("Add Custom Target…") { withAnimation(.smooth(duration: 0.2)) { addingCustom = true } }
            if !model.customTargets.isEmpty {
                Menu("Remove Custom Target") {
                    ForEach(model.customTargets, id: \.self) { value in
                        Button("\(LoudnessTarget.format(value)) LUFS") { model.removeCustomTarget(value) }
                    }
                }
            }
        } label: {
            Text(model.loudnessTarget.label)
        }
        .frame(maxWidth: .infinity)
    }

    private func option(_ target: LoudnessTarget) -> some View {
        Toggle(target.label, isOn: Binding(get: { model.loudnessTarget == target },
                                           set: { if $0 { model.loudnessTarget = target } }))
    }
}

/// Inline "−16 LUFS [Cancel] [Add]" row, so nothing opens outside the panel.
private struct CustomTargetRow: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("−16", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($focused)
                .onSubmit(add)
            Text("LUFS").foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { close() }
            Button("Add", action: add)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(Self.parse(text) == nil)
        }
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private func add() {
        guard let value = Self.parse(text) else { return }
        model.addCustomTarget(value)
        close()
    }

    private func close() {
        withAnimation(.smooth(duration: 0.2)) { isPresented = false }
    }

    /// Accepts "16", "−16", "-16,5" and "−16 LUFS"; positive numbers mean negative LUFS.
    static func parse(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "LUFS", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value != 0, abs(value) <= 40 else { return nil }
        return -abs(value)
    }
}
