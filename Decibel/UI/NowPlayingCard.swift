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

/// Progress bar you can click or drag; it seeks when you let go.
private struct ProgressRow: View {
    let track: NowPlaying.Track
    let now: Date
    let seek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        let playing = track.duration > 0 ? track.position(at: now) / track.duration : 0
        let fraction = min(1, max(0, dragFraction ?? playing))
        let position = fraction * track.duration
        let active = hovering || dragFraction != nil

        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * fraction))
                    if active {
                        Circle()
                            .fill(.white)
                            .shadow(radius: 1)
                            .frame(width: 10, height: 10)
                            .offset(x: geo.size.width * fraction - 5)
                    }
                }
                .frame(height: active ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragFraction = Double(value.location.x / geo.size.width) }
                        .onEnded { value in
                            seek(min(1, max(0, Double(value.location.x / geo.size.width))) * track.duration)
                            dragFraction = nil
                        }
                )
                .onHover { hovering = $0 }
                .animation(.smooth(duration: 0.15), value: active)
            }
            .frame(height: 12)
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
