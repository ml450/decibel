import SwiftUI

/// Spotify / Music track with artwork, a clickable progress bar and ⏮ ⏯ ⏭.
struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let np = model.nowPlaying
        if let track = np.track {
            Card {
                HStack(spacing: 12) {
                    artwork(np.artwork)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.album.isEmpty || track.album == track.title ? track.artist : "\(track.artist) – \(track.album)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            ProgressRow(track: track, now: context.date) { np.seek(to: $0) }
                        }
                        .padding(.top, 1)
                    }
                    controls(np, playing: track.isPlaying)
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
                    Image(systemName: "music.note").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func controls(_ np: NowPlaying, playing: Bool) -> some View {
        if model.isSnapshot {
            // ImageRenderer can't draw AppKit-backed buttons; show the same glyphs.
            HStack(spacing: 10) {
                Image(systemName: "backward.fill")
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 22)
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 14))
        } else {
            buttons(np, playing: playing)
        }
    }

    private func buttons(_ np: NowPlaying, playing: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: np.previous) { Image(systemName: "backward.fill") }
                .help("Previous")
            Button(action: np.togglePlayPause) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 22)
            }
            .help(playing ? "Pause" : "Play")
            Button(action: np.next) { Image(systemName: "forward.fill") }
                .help("Next")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .foregroundStyle(.primary)
    }
}

/// Track progress you can click or drag; it seeks when you let go.
private struct ProgressRow: View {
    let track: NowPlaying.Track
    let now: Date
    let seek: (Double) -> Void

    @State private var scrub: Double?

    var body: some View {
        let playing = track.duration > 0 ? track.position(at: now) / track.duration : 0
        let position = (scrub ?? playing) * track.duration
        VStack(spacing: 2) {
            ThinSlider(value: playing,
                       onChange: { scrub = $0 },
                       onEnd: { seek($0 * track.duration); scrub = nil })
            HStack {
                Text(Self.time(position))
                Spacer()
                Text("−" + Self.time(max(0, track.duration - position)))
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
