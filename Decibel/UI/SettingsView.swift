import SwiftUI

/// Everything that used to live in the gear menu, plus calibration and the accent colour.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings")
            Divider()
            VStack(spacing: 8) {
                section("General") {
                    toggleRow("Launch at login",
                              isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Divider()
                    toggleRow("Show level in menu bar",
                              isOn: Binding(get: { model.showLevelInMenuBar }, set: { model.showLevelInMenuBar = $0 }))
                }

                section("Appearance") {
                    AccentPicker()
                }

                section("Calibration") {
                    Button {
                        model.backPage = .settings
                        model.page = .calibrate
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Calibrate \(model.device?.name ?? "device")")
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(calibrationStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.device == nil)
                }

                section("Decibel \(model.updater.currentVersion)") {
                    row("Updates") {
                        UpdateStatus()
                    }
                    Divider()
                    row("Share Decibel") {
                        Menu("Share") {
                            Button("Copy Link") { ShareDecibel.copyLink() }
                            Divider()
                            Button("Messages") { ShareDecibel.share(via: .composeMessage) }
                            Button("Mail") { ShareDecibel.share(via: .composeEmail) }
                            Button("AirDrop") { ShareDecibel.share(via: .sendViaAirDrop) }
                        }
                        .fixedSize()
                    }
                    Divider()
                    HStack {
                        Button("Uninstall Decibel…", role: .destructive) { Uninstaller.confirmAndUninstall(model: model) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Quit Decibel") { NSApp.terminate(nil) }
                            .keyboardShortcut("q")
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(12)
        }
    }

    private var calibrationStatus: String {
        guard let p = model.currentProfile else { return "No output device" }
        return p.calibrated ? "Calibrated" : "Using the default estimate for \(p.kind.label.lowercased())"
    }

    // MARK: Building blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        Card {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            trailing()
        }
        .frame(minHeight: 24)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A row of colour dots; the panel recolours as you pick.
private struct AccentPicker: View {
    @State private var appearance = Appearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accent colour").font(.system(size: 13))
                Spacer()
                Text(appearance.accent.name).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(AccentChoice.allCases) { choice in
                    let selected = appearance.accent == choice
                    Circle()
                        .fill(choice.color.gradient)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? choice.color : .clear, lineWidth: 2))
                        .frame(maxWidth: .infinity)
                        .contentShape(Circle())
                        .onTapGesture { withAnimation(.smooth(duration: 0.25)) { appearance.accent = choice } }
                        .help(choice.name)
                }
            }
        }
    }
}

/// "Up to date" / "Check" / "Install 2.2" in the About section.
private struct UpdateStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updater = model.updater
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
                .font(.caption)
        case .available(let version):
            Button("Install \(version)") { Task { await updater.install(beforeQuit: { model.flush() }) } }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
        case .upToDate:
            Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button("Try again") { Task { await updater.check() } }.controlSize(.small)
        case .idle:
            Button("Check now") { Task { await updater.check() } }.controlSize(.small)
        }
    }
}
