import SwiftUI

/// Everything that used to live in the gear menu, plus the accent colour.
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


    // MARK: Building blocks

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        SectionCard(title: title) { content() }
    }

    static let buttonWidth: CGFloat = 84

    private func row(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            trailing().controlSize(.regular)
        }
        .frame(minHeight: 28)
    }

    private func actionButton(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(destructive ? .red : .primary)   // plain buttons stay neutral; only toggles take the accent
        .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .frame(width: Self.buttonWidth)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .tint(Theme.accent)   // only the switches take the accent; buttons and menus stay neutral
        }
    }
}

/// A row of colour dots, the last one a rainbow that opens a colour wheel; the panel recolours as you pick.
private struct AccentPicker: View {
    @State private var appearance = Appearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent colour").font(.system(size: 13))
            HStack(spacing: 0) {
                ForEach(AccentChoice.allCases) { choice in
                    let selected = appearance.accent == choice
                    swatch(choice)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .shadow(radius: 1)
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
            if appearance.accent == .custom {
                ColorWheel(hue: $appearance.customHue, saturation: $appearance.customSaturation)
                    .frame(width: 132, height: 132)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
    }

    @ViewBuilder
    private func swatch(_ choice: AccentChoice) -> some View {
        if choice == .custom {
            Circle().fill(AngularGradient(colors: ColorWheel.hues, center: .center))
        } else {
            Circle().fill(choice.color.gradient)
        }
    }
}

/// Hue around the circle, saturation from the centre (white) to the edge. Drag or click to pick.
struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double

    static let hues: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 0.96) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Hue 0 at the right, increasing counter-clockwise, matching AngularGradient's layout.
            let angle = hue * 2 * .pi
            let knob = CGPoint(x: centre.x + cos(angle) * radius * saturation,
                               y: centre.y + sin(angle) * radius * saturation)
            ZStack {
                Circle().fill(AngularGradient(colors: Self.hues, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: radius))
                Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 0.96))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .position(knob)
            }
            .frame(width: size, height: size)
            .position(centre)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = g.location.x - centre.x, dy = g.location.y - centre.y
                var a = atan2(dy, dx) / (2 * .pi)
                if a < 0 { a += 1 }
                hue = a
                saturation = min(1, max(0.15, sqrt(dx * dx + dy * dy) / radius))
            })
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
        .frame(width: SettingsPage.buttonWidth, height: 26)
    }

    @ViewBuilder
    private func button(_ title: String, prominent: Bool = false, action: @escaping () async -> Void) -> some View {
        let b = Button { Task { await action() } } label: { Text(title).frame(maxWidth: .infinity) }
        if prominent {
            b.buttonStyle(.borderedProminent).tint(Theme.accent)
        } else {
            b.buttonStyle(.bordered).tint(.primary).foregroundStyle(.primary)
        }
    }
}
