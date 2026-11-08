import Charts
import SwiftUI

/// The menu bar panel (Dropbox-sized popover). Its height follows the content.
struct PanelView: View {
    static let width: CGFloat = 360

    @Environment(AppModel.self) private var model
    /// Height of the Hearing tab; the Loudness tab takes the same, so switching never resizes the panel.
    @State private var hearingHeight: CGFloat?

    /// Same soft fade-and-scale as the popover opening.
    private static let pageTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top))

    var body: some View {
        ZStack(alignment: .top) {
            switch model.page {
            case .home, .loudness:
                // The two tabs share the tab bar and footer; only their content changes.
                VStack(spacing: 0) {
                    PanelTabs()
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    // Both tabs stay laid out, so the panel keeps the taller one's height and never
                    // jumps when switching; they crossfade with a short slide instead.
                    ZStack(alignment: .top) {
                        tab(HomePage().onHeightChange { hearingHeight = $0 }, selected: model.page == .home, from: -1)
                        tab(LoudnessTab().frame(height: hearingHeight), selected: model.page == .loudness, from: 1)
                    }
                    .animation(.smooth(duration: 0.3), value: model.page)
                    Divider()
                    FooterBar()
                }
                .transition(Self.pageTransition)
            case .settings: SettingsPage().transition(Self.pageTransition)
            case .device(let uid):
                Group {
                    if let profile = model.profiles[uid] { DeviceEditPage(profile: profile) } else { HomePage() }
                }
                .transition(Self.pageTransition)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.page)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // No background of our own: the popover's material (arrow included) shows through as one surface.
    }
}

extension PanelView {
    private func tab(_ content: some View, selected: Bool, from side: CGFloat) -> some View {
        content
            .opacity(selected ? 1 : 0)
            .offset(x: selected ? 0 : side * 24)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            .onPreferenceChange(HeightKey.self, perform: action)
    }
}

// MARK: - Home

private struct HomePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
    }
}

extension HomePage {
    private var content: some View {
        VStack(spacing: 8) {
            // Device and player as two matching tiles, always: the layout never changes when music stops.
            HStack(alignment: .top, spacing: 8) {
                DeviceTile().frame(maxHeight: .infinity)
                NowPlayingTile().frame(maxHeight: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            // Only problems get a card. "Starting" lasts a moment and would make the panel jump.
            if model.captureState.needsAttention && !model.isSnapshot { CaptureStatusCard() }
            LevelsCard()
            DevicesCard()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .animation(.smooth(duration: 0.3), value: model.nowPlaying.track?.key)
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
    /// Scrolling over the chart moves back and forth in time, like the Health app.
    @State private var scroller = PeriodScroller()
    /// Which way the last step went, so the chart slides in from the right side.
    @State private var lastStep = -1

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
                        .foregroundStyle(avg >= 80 ? Theme.loud : Theme.safe)
                    Text(avg >= 80 ? "Loud" : "OK").fontWeight(.semibold)
                        .foregroundStyle(avg >= 80 ? Theme.loud : Theme.safe)
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
                    Text(model.periodOffset == 0 ? "No listening yet" : "No listening")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .id("\(range.rawValue)\(model.periodOffset)")
            .transition(.push(from: lastStep < 0 ? .leading : .trailing))
            .clipped()
            .onHover { inside in
                if inside {
                    scroller.start { delta in
                        lastStep = delta
                        selection = nil
                        var moved = false
                        withAnimation(.smooth(duration: 0.3)) { moved = model.shiftPeriod(delta) }
                        return moved
                    }
                } else {
                    scroller.stop()
                }
            }
            .onDisappear { scroller.stop() }
        }
        .onChange(of: model.range) { selection = nil }
    }

    /// Turns scroll-wheel notches and sideways trackpad swipes into one-period steps (−1 back, +1 forward).
@MainActor
final class PeriodScroller {
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var steppedThisGesture = false
    private var lastWheelStep = Date.distantPast

    func start(_ step: @escaping (Int) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event, step)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, _ step: (Int) -> Bool) {
        if event.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse: one step per sideways swipe, ignoring the momentum afterwards.
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) { accumulated = 0; steppedThisGesture = false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            accumulated += event.scrollingDeltaX
            if !steppedThisGesture, abs(accumulated) > 30 {
                steppedThisGesture = true
                // Fingers moving right pull in the past, like paging in Health.
                _ = step(accumulated > 0 ? -1 : 1)
            }
        } else {
            // Mouse wheel: each notch is a step (up/left = back), with a short pause so one flick isn't five.
            let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            guard d != 0, Date().timeIntervalSince(lastWheelStep) > 0.18 else { return }
            lastWheelStep = Date()
            _ = step(d > 0 ? -1 : 1)
        }
    }
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
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.75))
            }
        case .week:
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.75))
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day()).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.75))
            }
        case .sixMonths, .year:
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.75))
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
                FooterIcon(symbol: "gearshape", size: 16)
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

        Button { model.page = .settings } label: {
            FooterIcon(symbol: "gearshape", size: 16)
        }
        .buttonStyle(.borderless)
        .help("Settings")
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Same size and frame for every footer icon, so they share one baseline.
struct FooterIcon: View {
    let symbol: String
    var color: Color? = nil
    /// Optical sizes: a closed ring reads larger than a toothed gear at the same point size.
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
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
                case .running, .waiting, .starting:
                    // Just the version; the footer only speaks up when something needs attention.
                    Text("Decibel \(updater.currentVersion)").foregroundStyle(.secondary)
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
