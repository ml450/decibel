import Charts
import SwiftUI

/// The menu bar panel (Dropbox-sized popover). Its height follows the content.
struct PanelView: View {
    static let width: CGFloat = 360

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.page {
            case .home: HomePage()
            case .calibrate: CalibrationPage()
            case .device(let uid):
                if let profile = model.profiles[uid] { DeviceEditPage(profile: profile) } else { HomePage() }
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // No background of our own: the popover's material (arrow included) shows through as one surface.
    }
}

// MARK: - Home

private struct HomePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NowHeader()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            content

            Divider()
            FooterBar()
        }
    }
}

extension HomePage {
    private var content: some View {
        VStack(spacing: 8) {
            if !model.captureState.isHealthy && !model.isSnapshot { CaptureStatusCard() }
            LevelsCard()
            DoseCard()
            DevicesCard()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

private struct NowHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(symbol: model.currentProfile?.symbol ?? "speaker.wave.2.fill", size: 28)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(model.device?.name ?? "No output device")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if model.currentProfile?.calibrated == true {
                        Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(Theme.accent)
                            .help("Calibrated")
                    }
                }
                Text(volumeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let spl = model.liveSPL {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Circle().fill(Theme.levelColor(spl)).frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(Format.db(spl))
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("dB").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                .animation(.snappy, value: Int(spl))
            } else {
                Text(model.liveDBFS == nil ? "Silent" : "Muted")
                    .font(.callout.weight(.medium)).foregroundStyle(.tertiary)
            }
        }
    }

    private var volumeText: String {
        let v = model.volume
        if v.muted { return "Muted" }
        return v.hasControl ? "Volume \(Int((v.scalar * 100).rounded()))%" : (model.currentProfile?.kind.label ?? "")
    }
}

private struct CaptureStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            switch model.captureState {
            case .needsPermission:
                CardTitle(title: "Audio Access Needed", symbol: "lock.shield")
                Text("Decibel calculates how loud your Mac's sound output is, once per second. macOS asks before an app can read the system audio (**System Audio Recording Only**). Audio is never recorded or stored, and your screen is not captured.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow…") { model.requestPermission() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("Settings") { model.openPrivacySettings() }
                    Button("Relaunch") { model.relaunch() }
                }
                .controlSize(.small)
            case .failed(let message):
                CardTitle(title: "Measuring Stopped", symbol: "exclamationmark.triangle")
                Text(message).font(.callout).foregroundStyle(.secondary)
                Button("Try Again") { model.startCapture() }.controlSize(.small)
            case .starting, .running, .waiting:
                HStack { ProgressView().controlSize(.small); Text("Starting…").foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: Levels

private struct LevelsCard: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Date?

    var body: some View {
        @Bindable var model = model
        let s = model.summary
        let range = model.range
        let selected = selection.flatMap { date in
            s.buckets.first { Calendar.current.isDate($0.start, equalTo: date, toGranularity: range.bucket) }
        }
        let avg = selected?.avgDB ?? s.avgDB

        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("AVERAGE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Format.db(avg))
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("dB").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                RangeTabs(range: $model.range)
            }
            HStack(spacing: 5) {
                if let avg {
                    Image(systemName: avg >= 80 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(avg >= 80 ? Theme.loud : .green)
                    Text(avg >= 80 ? "Loud" : "OK").fontWeight(.semibold)
                        .foregroundStyle(avg >= 80 ? Theme.loud : .green)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(Format.duration(selected?.seconds ?? s.seconds))
                Text("·").foregroundStyle(.tertiary)
                Text(selected.map { bucketLabel($0.start) } ?? Format.rangeLabel(range, s.interval))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, -6)

            Chart {
                ForEach(slots(s, range), id: \.self) { d in
                    BarMark(x: .value("Time", d, unit: range.bucket),
                            yStart: .value("Floor", 30), yEnd: .value("Top", 110),
                            width: .ratio(0.55))
                        .foregroundStyle(Theme.accent.opacity(0.08))
                        .cornerRadius(4)
                }
                ForEach(s.buckets) { b in
                    BarMark(x: .value("Time", b.start, unit: range.bucket),
                            yStart: .value("Floor", 30),
                            yEnd: .value("Average", max(38, min(b.avgDB, 110))),
                            width: range == .sixMonths || range == .year ? .automatic : .ratio(0.55))
                        .foregroundStyle(b.avgDB >= 80 ? Theme.loud : Theme.accent)
                        .opacity(selected == nil || selected?.start == b.start ? 1 : 0.35)
                        .cornerRadius(4)
                }
                RuleMark(y: .value("Limit", 80))
                    .foregroundStyle(Theme.loud.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text("80").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.loud.opacity(0.8))
                    }
            }
            .chartXScale(domain: s.interval.start...s.interval.end)
            .chartYScale(domain: 30...110)
            .chartYAxis(.hidden)
            .chartXAxis { xAxis(range) }
            .chartXSelection(value: $selection)
            .frame(height: 104)
            .overlay {
                if s.buckets.isEmpty {
                    Text("No listening yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: model.range) { selection = nil }
    }

    /// Empty "track" bars behind the data for the short ranges.
    private func slots(_ s: RangeSummary, _ range: TimeRange) -> [Date] {
        guard [.day, .week, .month].contains(range) else { return [] }
        var out: [Date] = []
        var d = s.interval.start
        while d < s.interval.end, out.count < 40 {
            out.append(d)
            guard let next = Calendar.current.date(byAdding: range.bucket, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    private func bucketLabel(_ date: Date) -> String {
        model.range == .day
            ? date.formatted(.dateTime.hour())
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    @AxisContentBuilder
    private func xAxis(_ range: TimeRange) -> some AxisContent {
        switch range {
        case .day:
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        case .week:
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day()).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        case .sixMonths, .year:
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Small pill tabs instead of a full-width segmented control.
private struct RangeTabs: View {
    @Binding var range: TimeRange
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TimeRange.allCases) { r in
                Text(r.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(r == range ? Color.white : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background {
                        if r == range {
                            Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { range = r } }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

// MARK: Dose

private struct DoseCard: View {
    @Environment(AppModel.self) private var model

    /// What's left of the rolling 7-day allowance, expressed as listening time at 80 dB.
    private var remainingText: String {
        let left = (1 - model.weeklyDose) * Dose.referenceSeconds
        guard left > 0 else { return "Turn it down to let your ears recover" }
        let time = left >= 10 * 3600 ? "\(Int((left / 3600).rounded(.down))) h" : Format.duration(left)
        return "About \(time) left at 80 dB this week"
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                DoseRing(fraction: model.weeklyDose, lineWidth: 5, fontSize: 10)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.weeklyDose >= 1 ? "Weekly limit reached" : "7-day sound dose")
                        .font(.system(size: 13, weight: .semibold))
                    Text(remainingText)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct DoseRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 12
    var fontSize: CGFloat = 22

    var body: some View {
        let color: Color = fraction >= 1 ? .red : fraction >= 0.8 ? Theme.loud : Theme.accent
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.001), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if fraction > 1 {
                Circle()
                    .trim(from: 0, to: min(fraction - 1, 1))
                    .stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .animation(.easeOut, value: fraction)
    }
}

// MARK: Devices

private struct DevicesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.summary.devices
        // Only devices used in this range, plus the one playing now.
        // Order: in use, then connected, then the rest; most listened first within each group.
        let rank = { (p: DeviceProfile) -> Int in
            p.uid == model.device?.uid ? 0 : model.connectedUIDs.contains(p.uid) ? 1 : 2
        }
        let rows = model.profiles.values
            .filter { usage[$0.uid] != nil || $0.uid == model.device?.uid }
            .sorted {
                (rank($1), usage[$0.uid]?.seconds ?? 0, $1.name) > (rank($0), usage[$1.uid]?.seconds ?? 0, $0.name)
            }

        Card {
            Text("Devices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.element.uid) { index, p in
                if index > 0 { Divider().padding(.leading, 34) }
                Button { model.page = .device(p.uid) } label: {
                    HStack(spacing: 10) {
                        DeviceIcon(symbol: p.symbol, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                            connectionLabel(p)
                        }
                        Spacer()
                        if let u = usage[p.uid] {
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(Format.db(u.avgDB)) dB")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .foregroundStyle(u.avgDB >= 80 ? Theme.loud : .primary)
                                Text(Format.duration(u.seconds)).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No data").font(.caption).foregroundStyle(.tertiary)
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .opacity(rank(p) == 2 ? 0.45 : 1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension DevicesCard {
    @ViewBuilder
    private func connectionLabel(_ p: DeviceProfile) -> some View {
        if p.uid == model.device?.uid {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2.fill")
                Text("In use")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.accent)
        } else if model.connectedUIDs.contains(p.uid) {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("Connected")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Text("Not connected").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: Footer

private struct FooterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            FooterStatus()
            Spacer()
            if model.isSnapshot {
                // ImageRenderer can't draw AppKit-backed buttons and menus.
                ForEach(["gauge.with.needle", "gearshape"], id: \.self) { FooterIcon(symbol: $0) }
            } else {
                controls
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var controls: some View {
        UpdateButton()

        Button { model.page = .calibrate } label: {
            FooterIcon(symbol: "gauge.with.needle")
        }
        .buttonStyle(.borderless)
        .help("Calibrate device")
        .disabled(model.device == nil)

        Menu {
            Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            ShareLink(item: Uninstaller.downloadPage,
                      subject: Text("Decibel"),
                      message: Text("Decibel viser hvor høyt du hører, rett i menylinjen på Macen.")) {
                Text("Share Decibel…")
            }
            Divider()
            Button("Uninstall Decibel…") { Uninstaller.confirmAndUninstall(model: model) }
            Divider()
            Text("Decibel \(model.updater.currentVersion)")
            Button("Quit Decibel") { NSApp.terminate(nil) }
        } label: {
            FooterIcon(symbol: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }
}

/// Same size and frame for every footer icon, so they share one baseline.
struct FooterIcon: View {
    let symbol: String
    var color: Color? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(color ?? .primary)
            .frame(width: 22, height: 22)
    }
}

/// Measuring state, or what the updater is doing while it's busy.
private struct FooterStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = model.updater
        HStack(spacing: 6) {
            switch updater.state {
            case .checking:
                Text("Checking for updates…").foregroundStyle(.secondary)
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Decibel \(updater.currentVersion) is up to date")
            case .available(let version):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("Version \(version) available")
                Button("Install") { install() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing update…").foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.loud)
                Text(message).lineLimit(1).foregroundStyle(.secondary)
            case .idle:
                switch model.captureState {
                case .running:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Measuring")
                case .waiting:
                    Image(systemName: "waveform.circle.fill").foregroundStyle(.secondary)
                    Text("Waiting for sound").foregroundStyle(.secondary)
                default:
                    Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                    Text("Not measuring")
                }
            }
        }
        .font(.callout.weight(.medium))
    }

    private func install() {
        Task { await model.updater.install(beforeQuit: { model.flush() }) }
    }
}

/// Next to the gear: checks for updates, or installs one when it's available (blue dot).
private struct UpdateButton: View {
    @Environment(AppModel.self) private var model

    /// Only shown when an update is ready (or installing).
    var body: some View {
        let updater = model.updater
        if updater.state == .installing {
            ProgressView().controlSize(.small).frame(width: 22, height: 22)
        } else if updater.updateAvailable {
            Button {
                Task { await updater.install(beforeQuit: { model.flush() }) }
            } label: {
                FooterIcon(symbol: "arrow.down.circle.fill", color: Theme.accent)
            }
            .buttonStyle(.borderless)
            .help("Install update")
            .transition(.scale.combined(with: .opacity))
        }
    }
}
