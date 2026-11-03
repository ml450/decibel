import SwiftUI

/// Live level, shared by the wide header and the compact tile.
struct LiveLevel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
            Text(model.volume.isSilent && model.liveDBFS != nil ? "Muted" : "Silent")
                .font(.callout.weight(.medium)).foregroundStyle(.tertiary)
        }
    }
}

/// Compact device tile: icon and live level, name, kind, volume slider.
struct DeviceTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .center) {
                DeviceIcon(symbol: model.currentProfile?.symbol ?? "speaker.wave.2.fill", size: 36)
                Spacer(minLength: 4)
                LiveLevel()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.device?.name ?? "No output device")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.currentProfile?.kind.label ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.volume.hasControl {
                HStack(spacing: 5) {
                    Image(systemName: model.volume.muted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    ThinSlider(value: model.volume.muted ? 0 : model.volume.scalar,
                               onChange: { model.setVolume($0) })
                    Text(model.volume.muted ? "Off" : "\(Int((model.volume.scalar * 100).rounded()))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .help("Volume")
            }
        }
    }
}

/// Compact player tile: artwork and controls, title, artist, progress.
struct NowPlayingTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let np = model.nowPlaying
        if let track = np.track {
            Card {
                HStack(alignment: .center) {
                    artwork(np.artwork)
                    Spacer(minLength: 4)
                    controls(np, playing: track.isPlaying)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let progress = track.duration > 0 ? track.position(at: context.date) / track.duration : 0
                    ThinSlider(value: progress, onEnd: { np.seek(to: $0 * track.duration) })
                }
            }
        }
    }

    private func artwork(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Theme.accent.gradient)
                    Image(systemName: "music.note").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func controls(_ np: NowPlaying, playing: Bool) -> some View {
        let glyphs = HStack(spacing: 9) {
            Image(systemName: "backward.fill")
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 16)).frame(width: 16)
            Image(systemName: "forward.fill")
        }
        .font(.system(size: 11))
        if model.isSnapshot {
            glyphs   // ImageRenderer can't draw AppKit-backed buttons
        } else {
            HStack(spacing: 9) {
                Button(action: np.previous) { Image(systemName: "backward.fill") }.help("Previous")
                Button(action: np.togglePlayPause) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 16)).frame(width: 16)
                }
                .help(playing ? "Pause" : "Play")
                Button(action: np.next) { Image(systemName: "forward.fill") }.help("Next")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
        }
    }
}
