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
                        .padding(.top, 3)
                    }
                    controls(np, playing: track.isPlaying)
                }
            }
            .help("\(track.player.appName)")
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

    private func controls(_ np: NowPlaying, playing: Bool) -> some View {
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

private struct ProgressRow: View {
    let track: NowPlaying.Track
    let now: Date
    let seek: (Double) -> Void

    var body: some View {
        let position = track.position(at: now)
        let fraction = track.duration > 0 ? position / track.duration : 0
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * fraction))
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    seek(Double(point.x / geo.size.width) * track.duration)
                }
            }
            .frame(height: 4)
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
