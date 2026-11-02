import SwiftUI

/// Back-button header used by the panel's sub-pages.
struct PageHeader: View {
    @Environment(AppModel.self) private var model
    let title: String

    var body: some View {
        ZStack {
            Text(title).font(.headline)
            HStack {
                Button { model.page = .home } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct CalibrationPage: View {
    @Environment(AppModel.self) private var model

    @State private var player = PinkNoisePlayer()
    @State private var playing = false
    @State private var noiseLevel: Double?
    @State private var measured: Double?
    @State private var error: String?

    var body: some View {
        let profile = model.currentProfile
        let volumeDB = model.volume.isSilent ? nil : model.volume.decibels

        VStack(spacing: 0) {
            PageHeader(title: "Calibrate Device")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        DeviceIcon(symbol: profile?.symbol ?? "speaker.wave.2.fill", size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(profile?.name ?? "No output device").font(.headline)
                            Text(model.volume.muted ? "Muted" : "Volume \(Int((model.volume.scalar * 100).rounded()))%"
                                 + (volumeDB.map { String(format: " (%.1f dB)", $0) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "Set the volume you normally listen at.")
                        step(2, "Play pink noise (−20 dBFS). Start at a moderate volume.")
                        step(3, profile?.kind == .headphones
                             ? "Measure the level at the ear (e.g. iPhone Health headphone level, or an SPL meter)."
                             : "Measure at your listening position with Apple Watch Noise or an SPL meter app (dB A).")
                        step(4, "Enter the reading and save. Later volume changes are handled automatically.")
                    }
                    .font(.callout)

                    Card {
                        Button { toggle() } label: {
                            Label(playing ? "Stop Pink Noise" : "Play Pink Noise", systemImage: playing ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .controlSize(.large)

                        HStack {
                            Text("Measured level")
                            Spacer()
                            TextField("dB(A)", value: $measured, format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Text("dB(A)").foregroundStyle(.secondary)
                        }

                        if let p = profile, let n = noiseLevel, let v = volumeDB {
                            Divider()
                            row("Current estimate", String(format: "%.1f dB", n + v + p.offset))
                            row("Offset", measured.map { String(format: "%.1f → %.1f dB", p.offset, $0 - (n + v)) }
                                ?? String(format: "%.1f dB", p.offset))
                        }
                    }

                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .padding(14)
            Divider()
            HStack {
                if let p = profile, p.calibrated {
                    Button("Reset to Default") {
                        var reset = p
                        reset.offset = p.kind.defaultOffset
                        reset.calibrated = false
                        model.save(reset)
                    }
                }
                Spacer()
                Button("Save") {
                    guard let m = measured, let n = noiseLevel else { return }
                    if model.calibrate(measuredDB: m, noiseDBFS: n) {
                        model.page = .home
                    } else {
                        error = "Turn the volume up and unmute before saving."
                    }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(measured == nil || noiseLevel == nil || volumeDB == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .onAppear { model.setPanelPinned?(true) }
        .onDisappear {
            player.stop()
            model.setPanelPinned?(false)
        }
    }

    private func toggle() {
        if playing {
            player.stop()
            playing = false
        } else {
            do {
                try player.start()
                noiseLevel = player.aWeightedDBFS
                playing = true
                error = nil
            } catch {
                self.error = "Couldn't play noise: \(error.localizedDescription)"
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Theme.accent, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

struct DeviceEditPage: View {
    @Environment(AppModel.self) private var model
    @State private var profile: DeviceProfile

    init(profile: DeviceProfile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Device")
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    DeviceIcon(symbol: profile.symbol, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(profile.name).font(.headline)
                        Text(profile.transport.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    Picker("Type", selection: $profile.kind) {
                        ForEach(DeviceKind.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: profile.kind) { _, kind in
                        if !profile.calibrated { profile.offset = kind.defaultOffset }
                    }
                    HStack {
                        Text("Offset")
                        Spacer()
                        TextField("", value: $profile.offset, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Stepper("", value: $profile.offset, in: 40...140, step: 0.5).labelsHidden()
                        Text("dB").foregroundStyle(.secondary)
                    }
                    Text("Estimated dB(A) for a full-scale signal at maximum volume. "
                         + (profile.calibrated ? "Calibrated." : "Default for \(profile.kind.label.lowercased()): \(Int(profile.kind.defaultOffset)) dB."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if profile.uid == model.device?.uid {
                    Button("Calibrate This Device…") { model.page = .calibrate }
                }
            }
            .padding(14)
            Divider()
            HStack {
                Button("Reset to Default") {
                    profile.offset = profile.kind.defaultOffset
                    profile.calibrated = false
                }
                Spacer()
                Button("Save") {
                    model.save(profile)
                    model.reloadStats()
                    model.page = .home
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
