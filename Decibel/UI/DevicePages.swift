import SwiftUI

/// Back-button header used by the panel's sub-pages.
struct PageHeader: View {
    @Environment(AppModel.self) private var model
    let title: String

    var body: some View {
        ZStack {
            Text(title).font(.headline)
            HStack {
                Button { model.goBack() } label: {
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
                         + (profile.calibrated ? "Custom value." : "Default for \(profile.kind.label.lowercased()): \(Int(profile.kind.defaultOffset)) dB."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    // A hand-tuned value is remembered as such, so new defaults never overwrite it.
                    profile.calibrated = profile.offset != profile.kind.defaultOffset
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
