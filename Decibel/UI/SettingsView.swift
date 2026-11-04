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
                    // Same row everywhere: name on the left, one equally sized button on the right.
                    row("Updates") { UpdateStatus() }
                    Divider()
                    row("Share Decibel") {
                        // A plain button like the others (a SwiftUI Menu ignores the width); it pops up the menu.
                        actionButton("Share…") { ShareDecibel.showMenu() }
                    }
                    Divider()
                    row("Quit Decibel") {
                        actionButton("Quit") { NSApp.terminate(nil) }
                            .keyboardShortcut("q")
                    }
                    Divider()
                    row("Uninstall Decibel") {
                        actionButton("Uninstall…", destructive: true) { Uninstaller.confirmAndUninstall(model: model) }
                    }
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
        SectionCard(title: title) { content() }
    }

    static let buttonWidth: CGFloat = 96

    private func row(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            trailing().controlSize(.small)
        }
        .frame(minHeight: 24)
    }

    private func actionButton(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .frame(width: Self.buttonWidth)
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
        Group {
            switch updater.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .installing:
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            case .available(let version):
                button("Install \(version)", prominent: true) { await updater.install(beforeQuit: { model.flush() }) }
            case .upToDate:
                Text("Up to date").font(.caption).foregroundStyle(.secondary)
            case .failed:
                button("Try again") { await updater.check() }
            case .idle:
                button("Check now") { await updater.check() }
            }
        }
        .frame(width: SettingsPage.buttonWidth, height: 22)
    }

    @ViewBuilder
    private func button(_ title: String, prominent: Bool = false, action: @escaping () async -> Void) -> some View {
        let b = Button { Task { await action() } } label: { Text(title).frame(maxWidth: .infinity) }
        if prominent {
            b.buttonStyle(.borderedProminent).tint(Theme.accent)
        } else {
            b.buttonStyle(.bordered)
        }
    }
}
