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
    @ObservationIgnored private var scripts: [String: NSAppleScript] = [:]
    @ObservationIgnored private var denied: Set<Player> = []

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
        // Prefer whichever app is actually playing; otherwise show a paused track.
        let tracks = Player.allCases.compactMap(read)
        let next = tracks.first(where: \.isPlaying) ?? tracks.first
        if next != track { track = next }
        if let next, next.key != artworkKey { loadArtwork(for: next) }
        if next == nil, artwork != nil { artwork = nil; artworkKey = nil }
    }

    private func read(_ player: Player) -> Track? {
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
        guard let text = run(source, for: player)?.stringValue, !text.isEmpty else { return nil }
        let f = text.components(separatedBy: "\u{1F}")
        guard f.count >= 7 else { return nil }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return Track(player: player, title: f[1], artist: f[2], album: f[3],
                     duration: number(f[4]), position: number(f[5]), isPlaying: f[0] == "playing",
                     artworkURL: URL(string: f[6]))
    }

    // MARK: Controls

    func togglePlayPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        guard let track else { return }
        let value = String(format: "%.1f", max(0, min(seconds, track.duration)))
        command("set player position to \(value)")
    }

    private func command(_ verb: String) {
        guard let player = track?.player else { return }
        _ = run("tell application id \"\(player.rawValue)\" to \(verb)", for: player)
        poll()
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
            if let data = run(source, for: .music)?.data, !data.isEmpty {
                artwork = NSImage(data: data)
            }
        }
    }

    // MARK: AppleScript

    private func run(_ source: String, for player: Player) -> NSAppleEventDescriptor? {
        let script = scripts[source] ?? {
            let s = NSAppleScript(source: source)!
            scripts[source] = s
            return s
        }()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            // -1743: the user said no to "Decibel wants to control …"; don't keep asking.
            if code == -1743 { denied.insert(player) }
            return nil
        }
        return result
    }

    // MARK: Demo

    /// Sample track for `--snapshot --demo`.
    func applyDemo() {
        track = Track(player: .spotify, title: "Weightless", artist: "Marconi Union", album: "Weightless",
                      duration: 480, position: 151, isPlaying: true, artworkURL: nil)
    }
}
