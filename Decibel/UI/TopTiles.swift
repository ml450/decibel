import SwiftUI

/// Live level as a big number ("56 dB"), coloured green / yellow / red by level; grey "Silent" when quiet.
/// Takes the place of the device icon in both the tile and the wide header.
struct LiveLevel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let spl = model.liveSPL {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(Format.db(spl))
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.levelColor(spl))
                        .contentTransition(.numericText())
                    Text("dB").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .animation(.snappy, value: Int(spl))
            } else {
                Text(model.volume.isSilent && model.liveDBFS != nil ? "Muted" : "Silent")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: NowPlayingTile.topRow, alignment: .leading)   // same height as the album cover next to it
    }
}

/// Compact device tile: icon and live level, name, kind, volume slider.
struct DeviceTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            LiveLevel()
            VStack(alignment: .leading, spacing: 1) {
                Text(model.device?.name ?? "No output device")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.currentProfile?.kind.label ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.volume.hasControl {
                HStack(spacing: 5) {
                    VolumeButton()
                    ThinSlider(value: model.volume.muted ? 0 : model.volume.scalar,
                               onChange: { model.setVolume($0) })
                    Text(model.volume.muted ? "Off" : "\(Int((model.volume.scalar * 100).rounded()))%")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
    }
}

/// Compact player tile: artwork and controls, title, artist, progress.
struct NowPlayingTile: View {
    @Environment(AppModel.self) private var model
    static let topRow: CGFloat = 36

    /// Always shown, so the panel keeps its layout when Spotify or Music closes; empty state when idle.
    var body: some View {
        let np = model.nowPlaying
        let track = np.track
        Card {
            HStack(alignment: .center, spacing: 0) {
                artwork(track == nil ? nil : np.artwork, idle: track == nil)
                // Centred between the cover and the card's wall (the card's 12 pt padding included),
                // and between the card's top and the title, which is the cover's centre line.
                controls(np, playing: track?.isPlaying ?? false)
                    .disabled(track == nil)
                    .opacity(track == nil ? 0.3 : 1)
                    .frame(maxWidth: .infinity)
                    .offset(x: 6, y: -1)
            }
            .frame(height: Self.topRow)   // same as the device tile, so the titles line up
            VStack(alignment: .leading, spacing: 1) {
                Text(track?.title ?? "Not playing")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(track == nil ? .secondary : .primary)
                Text(track?.artist ?? "Spotify or Music")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let track {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let progress = track.duration > 0 ? track.position(at: context.date) / track.duration : 0
                    ThinSlider(value: progress, onEnd: { np.seek(to: $0 * track.duration) })
                }
            } else {
                ThinSlider(value: 0).disabled(true).opacity(0.5)
            }
        }
    }

    private func artwork(_ image: NSImage?, idle: Bool) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(idle ? AnyShapeStyle(Color.secondary.opacity(0.18)) : AnyShapeStyle(Theme.accent.gradient))
                    Image(systemName: "music.note").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(idle ? Color.secondary : Color.white)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func controls(_ np: NowPlaying, playing: Bool) -> some View {
        let glyphs = HStack(spacing: 7) {
            Image(systemName: "backward.fill")
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 25)).frame(width: 24)
            Image(systemName: "forward.fill")
        }
        .font(.system(size: 17))
        if model.isSnapshot {
            glyphs   // ImageRenderer can't draw AppKit-backed buttons
        } else {
            HStack(spacing: 7) {
                Button(action: np.previous) { Image(systemName: "backward.fill") }.help("Previous")
                Button(action: np.togglePlayPause) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 25)).frame(width: 24)
                }
                .help(playing ? "Pause" : "Play")
                Button(action: np.next) { Image(systemName: "forward.fill") }.help("Next")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 17))
            .foregroundStyle(.primary)
        }
    }
}

/// Speaker icon with 0–3 waves by volume (crossed out when muted); click to mute or unmute.
struct VolumeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let v = model.volume
        if model.isSnapshot {
            icon(v)   // ImageRenderer can't draw AppKit-backed buttons
        } else {
            Button { model.toggleMute() } label: { icon(v) }
                .buttonStyle(.borderless)
                .help(v.muted ? "Unmute" : "Mute")
        }
    }

    private func icon(_ v: VolumeInfo) -> some View {
        Image(systemName: Self.symbol(v))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 16, alignment: .leading)   // fixed, so the slider doesn't move as waves come and go
            .contentTransition(.symbolEffect(.replace))
    }

    static func symbol(_ v: VolumeInfo) -> String {
        if v.muted { return "speaker.slash.fill" }
        switch v.scalar {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
