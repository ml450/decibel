import AppKit
import Observation

/// What Spotify or Music is playing, read through their AppleScript interfaces (macOS asks once per app).
/// Only polled while the panel is open, and never launches either app.
@MainActor @Observable
final class NowPlaying {
    enum Player: String, CaseIterable {
        case spotify = "com.spotify.client"
        case music = "com.apple.Music"

        var appName: String { self == .spotify ? "Spotify" : "Music" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }

    struct Track: Equatable {
        var player: Player
        var title: String
        var artist: String
        var album: String
        var duration: Double      // seconds
        var position: Double      // seconds, at `readAt`
        var isPlaying: Bool
        var artworkURL: URL?      // Spotify
        var readAt = Date()

        /// Position now, extrapolated between polls while playing.
        func position(at date: Date) -> Double {
            min(duration, position + (isPlaying ? date.timeIntervalSince(readAt) : 0))
        }

        var key: String { "\(player.rawValue)|\(title)|\(artist)|\(album)" }
    }

    private(set) var track: Track?
    private(set) var artwork: NSImage?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private let scripts = ScriptRunner()
    @ObservationIgnored private var denied: Set<Player> = []
    @ObservationIgnored private var polling = false
    /// Ignore polls for a moment after a button press, so the optimistic state isn't overwritten by a stale read.
    @ObservationIgnored private var holdUntil = Date.distantPast

    // MARK: Polling

    func startPolling() {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        guard !polling else { return }
        polling = true
        Task {
            var tracks: [Track] = []
            for player in Player.allCases {
                if let t = await read(player) { tracks.append(t) }
            }
            polling = false
            guard Date() >= holdUntil else { return }
            // Prefer whichever app is actually playing; otherwise show a paused track.
            let next = tracks.first(where: \.isPlaying) ?? tracks.first
            if next != track { track = next }
            if let next, next.key != artworkKey { loadArtwork(for: next) }
            if next == nil, artwork != nil { artwork = nil; artworkKey = nil }
        }
    }

    private func read(_ player: Player) async -> Track? {
        guard player.isRunning, !denied.contains(player) else { return nil }
        let sep = "character id 31"
        let source: String
        switch player {
        case .spotify:
            source = """
            tell application id "com.spotify.client"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & ((duration of t) / 1000) & \(sep) & player position & \(sep) & (artwork url of t)
            end tell
            """
        case .music:
            source = """
            tell application id "com.apple.Music"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & (duration of t) & \(sep) & player position & \(sep) & ""
            end tell
            """
        }
        guard let text = await run(source, for: player).string, !text.isEmpty else { return nil }
        let f = text.components(separatedBy: "\u{1F}")
        guard f.count >= 7 else { return nil }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return Track(player: player, title: f[1], artist: f[2], album: f[3],
                     duration: number(f[4]), position: number(f[5]), isPlaying: f[0] == "playing",
                     artworkURL: URL(string: f[6]))
    }

    // MARK: Controls

    /// Buttons update the card at once and send the command in the background (Spotify can take a moment).
    func togglePlayPause() {
        guard var t = track else { return }
        t.position = t.position(at: Date())
        t.readAt = Date()
        t.isPlaying.toggle()
        track = t
        command("playpause")
    }

    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        guard var t = track else { return }
        let value = max(0, min(seconds, t.duration))
        t.position = value
        t.readAt = Date()
        track = t
        command("set player position to \(String(format: "%.1f", value))")
    }

    private func command(_ verb: String) {
        guard let player = track?.player else { return }
        holdUntil = Date().addingTimeInterval(0.8)
        Task {
            _ = await run("tell application id \"\(player.rawValue)\" to \(verb)", for: player)
            try? await Task.sleep(for: .milliseconds(900))
            poll()
        }
    }

    // MARK: Artwork

    private func loadArtwork(for track: Track) {
        artworkKey = track.key
        artwork = nil
        switch track.player {
        case .spotify:
            guard let url = track.artworkURL else { return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      artworkKey == track.key else { return }
                artwork = NSImage(data: data)
            }
        case .music:
            let source = "tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track"
            Task {
                guard let data = await run(source, for: .music).data, !data.isEmpty,
                      artworkKey == track.key else { return }
                artwork = NSImage(data: data)
            }
        }
    }

    // MARK: AppleScript

    private func run(_ source: String, for player: Player) async -> ScriptRunner.Result {
        let result = await scripts.run(source)
        // -1743: the user said no to "Decibel wants to control …"; don't keep asking.
        if result.error == -1743 { denied.insert(player) }
        return result
    }

    // MARK: Demo

    /// Sample track for `--snapshot --demo`.
    func applyDemo() {
        track = Track(player: .spotify, title: "Weightless", artist: "Marconi Union", album: "Weightless",
                      duration: 480, position: 151, isPlaying: true, artworkURL: nil)
    }
}

/// Runs AppleScript on one background queue (NSAppleScript isn't thread-safe), caching compiled scripts.
final class ScriptRunner: @unchecked Sendable {
    struct Result: Sendable {
        var string: String?
        var data: Data?
        var error: Int?
    }

    private let queue = DispatchQueue(label: "decibel.nowplaying.scripts", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]   // queue only

    func run(_ source: String) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                let script = self.cache[source] ?? {
                    let s = NSAppleScript(source: source)!
                    self.cache[source] = s
                    return s
                }()
                var error: NSDictionary?
                let descriptor = script.executeAndReturnError(&error)
                continuation.resume(returning: Result(string: descriptor.stringValue, data: descriptor.data,
                                                      error: error?[NSAppleScript.errorNumber] as? Int))
            }
        }
    }
}
