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
    /// The custom target being created or edited in the inline row (nil = row hidden).
    @State private var editing: CustomLoudnessTarget?

    var body: some View {
        let r = model.loudness
        let target = model.loudnessTarget
        let goal = model.targetLUFS

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TargetMenu(editing: $editing)
                if case .custom(let current) = target, editing == nil {
                    Button { withAnimation(.smooth(duration: 0.2)) { editing = current } } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.canPickLoudnessSource { SourceMenu() }
            }
            if let draft = editing {
                Card { CustomTargetEditor(draft: draft, editing: $editing) }
                    .id(draft.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Card {
                Spacer(minLength: 8)
                VStack(spacing: 2) {
                    Text("INTEGRATED")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(r?.integrated.map(Self.number) ?? "–")
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(r?.integrated.map { Self.color($0 - goal) } ?? .secondary)
                            .contentTransition(.numericText())
                        if r?.integrated != nil {
                            Text("LUFS").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text(verdict(r, target, goal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 12)

                LiveBar(value: r?.shortTerm, target: goal)

                Divider().padding(.vertical, 4)

                HStack(alignment: .top, spacing: 0) {
                    stat("Max", r?.shortTermMax, unit: "LUFS")
                    stat("Range", r?.range, unit: "LU")
                    stat("True peak", r?.truePeak, unit: "dBTP", warn: (r?.truePeak ?? -100) > -1)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
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
                .buttonStyle(.bordered)
                .tint(.primary)
                .disabled(r == nil)
            }
            .controlSize(.large)
        }
        .padding(12)
    }

    private func stat(_ title: String, _ value: Double?, unit: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map(Self.number) ?? "–")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? .secondary : warn ? Theme.loud : .primary)
                if value != nil { Text(unit).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verdict(_ r: LoudnessReading?, _ target: LoudnessTarget, _ goal: Double) -> String {
        guard let r else {
            return model.loudnessSource.map { "Press Start, then play from the beginning. Only \($0) is measured." }
                ?? "Press Start, then play from the beginning. Mute other apps meanwhile."
        }
        guard let integrated = r.integrated else {
            return model.loudnessRunning ? "Listening… values appear after a few seconds of sound." : "No sound measured."
        }
        let diff = integrated - goal
        let time = " · \(Self.duration(r.seconds))"
        if abs(diff) < 1 { return "On target" + time }
        let amount = String(format: "%.1f", abs(diff))
        let goalText = Self.number(goal).replacingOccurrences(of: ".0", with: "")
        return (diff > 0
            ? "\(amount) LU louder than \(goalText) LUFS.\(target.tooLoudNote)"
            : "\(amount) LU quieter than \(goalText) LUFS.") + time
    }

    /// Green within ±1 LU of the target, yellow within ±2, orange beyond.
    static func color(_ diff: Double) -> Color {
        abs(diff) < 1 ? Theme.safe : abs(diff) < 2 ? .yellow : Theme.loud
    }

    static func number(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: "-", with: "−")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Short-term loudness as one horizontal bar, with a tick at the target.
private struct LiveBar: View {
    let value: Double?
    let target: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Short-term").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.map(LoudnessTab.number) ?? "–")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: value.map { Meter.y($0, w) } ?? 0)
                        .animation(.linear(duration: 0.15), value: value)
                    Rectangle().fill(Color.primary.opacity(0.8))
                        .frame(width: 2, height: 12)
                        .offset(x: Meter.y(target, w) - 1)
                }
            }
            .frame(height: 8)
        }
    }

    private var color: Color {
        guard let value else { return Theme.accent }
        return value > target + 1 ? Theme.loud : value >= target - 1 ? Theme.safe : Theme.accent
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
        return value > target + 1 ? Theme.loud : value >= target - 1 ? Theme.safe : Theme.accent
    }
}

/// Built-in and saved targets, plus "New Target…". Editing and deleting live in the inline editor.
private struct TargetMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: CustomLoudnessTarget?

    var body: some View {
        Menu {
            ForEach(LoudnessTarget.builtIn, id: \.self) { option($0) }
            if !model.customTargets.isEmpty {
                Divider()
                ForEach(model.customTargets) { option(.custom($0)) }
            }
            Divider()
            Button("New Target…") {
                withAnimation(.smooth(duration: 0.2)) { editing = CustomLoudnessTarget(name: "", lufs: -16) }
            }
        } label: {
            Text(model.loudnessTarget.label)
        }
        .fixedSize()
        .help("Loudness target")
    }

    private func option(_ target: LoudnessTarget) -> some View {
        Toggle(target.label, isOn: Binding(get: { model.loudnessTarget == target },
                                           set: { if $0 { model.loudnessTarget = target } }))
    }
}

/// Which audio the loudness meter listens to: everything, or one app.
private struct SourceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.audioApps
        Menu {
            option("All audio", nil)
            if !apps.isEmpty { Divider() }
            ForEach(apps, id: \.self) { option($0, $0) }
            if let chosen = model.loudnessSource, !apps.contains(chosen) {
                Divider()
                option("\(chosen) (not running)", chosen)
            }
        } label: {
            Label(model.loudnessSource ?? "All audio",
                  systemImage: model.loudnessSource == nil ? "speaker.wave.2" : "app.badge")
        }
        .fixedSize()
        .help("Measure all audio, or one app")
    }

    private func option(_ title: String, _ source: String?) -> some View {
        Toggle(title, isOn: Binding(get: { model.loudnessSource == source },
                                    set: { if $0 { model.loudnessSource = source } }))
    }
}

/// Inline editor for a custom target: name, value, and Delete (when it already exists) / Cancel / Save.
private struct CustomTargetEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: CustomLoudnessTarget?
    private let original: CustomLoudnessTarget
    @State private var name: String
    @State private var value: String
    @FocusState private var focus: Field?

    private enum Field { case name, value }

    init(draft: CustomLoudnessTarget, editing: Binding<CustomLoudnessTarget?>) {
        original = draft
        _editing = editing
        _name = State(initialValue: draft.name)
        _value = State(initialValue: LoudnessTarget.format(draft.lufs))
    }

    private var exists: Bool { model.customTargets.contains { $0.id == original.id } }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name, e.g. Podcast", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onSubmit(save)
                TextField("−16", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .focused($focus, equals: .value)
                    .onSubmit(save)
                Text("LUFS").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if exists {
                    Button("Delete", role: .destructive) {
                        model.deleteCustomTarget(original.id)
                        close()
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { close() }
                Button(exists ? "Save" : "Add", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(Self.parse(value) == nil)
            }
        }
        .onAppear { focus = .name }
        .onExitCommand(perform: close)
    }

    private func save() {
        guard let lufs = Self.parse(value) else { return }
        var target = original
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.lufs = lufs
        model.saveCustomTarget(target)
        close()
    }

    private func close() {
        withAnimation(.smooth(duration: 0.2)) { editing = nil }
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
