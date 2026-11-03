import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit
import ServiceManagement
import UserNotifications
import os

let log = Logger(subsystem: "local.decibel.app", category: "decibel")

enum PanelPage: Equatable {
    case home, calibrate, loudness, device(String)
}

enum CaptureState: Equatable {
    /// `waiting`: the tap is off because nothing is playing (so macOS shows no recording indicator).
    case starting, needsPermission, running, waiting, failed(String)

    var isHealthy: Bool { self == .running || self == .waiting }
}

@MainActor @Observable
final class AppModel {
    // Live
    private(set) var device: OutputDevice?
    private(set) var volume = VolumeInfo.unity
    private(set) var liveDBFS: Double?
    private(set) var liveSPL: Double?
    private(set) var captureState: CaptureState = .starting

    // History
    private(set) var profiles: [String: DeviceProfile] = [:]
    /// Output devices that are connected right now.
    private(set) var connectedUIDs: Set<String> = []
    private(set) var summary = RangeSummary.empty
    private(set) var weeklyDose = 0.0
    var range: TimeRange = .week { didSet { reloadStats() } }

    var page: PanelPage = .home

    // Loudness (LUFS) measurement for delivery checks
    private(set) var loudness: LoudnessReading?
    private(set) var loudnessRunning = false
    var loudnessTarget = LoudnessTarget(storageKey: UserDefaults.standard.string(forKey: "loudnessTarget")) {
        didSet { UserDefaults.standard.set(loudnessTarget.storageKey, forKey: "loudnessTarget") }
    }
    /// Saved custom targets (LUFS), newest last.
    private(set) var customTargets: [Double] = UserDefaults.standard.array(forKey: "customLUFSTargets") as? [Double] ?? [] {
        didSet { UserDefaults.standard.set(customTargets, forKey: "customLUFSTargets") }
    }
    var targetLUFS: Double { loudnessTarget.lufs }

    func addCustomTarget(_ lufs: Double) {
        let value = (min(0, max(-40, lufs)) * 10).rounded() / 10
        if !customTargets.contains(value) { customTargets.append(value) }
        loudnessTarget = .custom(value)
    }

    func removeCustomTarget(_ lufs: Double) {
        customTargets.removeAll { $0 == lufs }
        if loudnessTarget == .custom(lufs) { loudnessTarget = .social }
    }

    /// The coloured level next to the ear in the menu bar (some find it distracting).
    var showLevelInMenuBar: Bool = UserDefaults.standard.object(forKey: "showLevelInMenuBar") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showLevelInMenuBar, forKey: "showLevelInMenuBar")
            onLiveChange?()
        }
    }
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored var onLiveChange: (() -> Void)?
    /// Keeps the menu bar panel open while calibrating (you'll be looking at a meter elsewhere).
    @ObservationIgnored var setPanelPinned: ((Bool) -> Void)?
    @ObservationIgnored let store: DecibelStore
    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private let capture: SystemAudioSource = {
        if #available(macOS 14.2, *) { return SystemAudioTap() }
        return SystemAudioCapture()
    }()
    /// Core Audio taps need only "System Audio Recording Only" (no screen-sharing indicator).
    @ObservationIgnored private var usesTap: Bool { !(capture is SystemAudioCapture) }
    @ObservationIgnored private var lastPlaybackAt = Date.distantPast
    @ObservationIgnored private var lastSoundAt = Date.distantPast
    @ObservationIgnored private var pausing = false
    @ObservationIgnored private var startInFlight = false
    /// Set while the tap is paused because it only heard silence; holds the apps that had output open then.
    @ObservationIgnored private var silencePausedPlayers: Set<pid_t>?
    @ObservationIgnored private var lastVolume: VolumeInfo?

    /// Apps that currently have audio output open (shown in the footer while measuring).
    private(set) var listeningTo: [String] = []

    /// Other processes with audio output running (process taps only; ScreenCaptureKit always runs).
    private var playingProcesses: Set<pid_t> {
        if #available(macOS 14.2, *), usesTap { return AudioActivity.playingProcesses() }
        return [0]
    }
    @ObservationIgnored private let monitor = OutputDeviceMonitor()
    @ObservationIgnored private var pending: [DecibelStore.MinuteKey: LevelAccumulator] = [:]
    @ObservationIgnored private var lastLevelAt = Date.distantPast
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private let verbose = CommandLine.arguments.contains("--verbose")

    init(store: DecibelStore) {
        self.store = store
        profiles = Dictionary(uniqueKeysWithValues: ((try? store.devices()) ?? []).map { ($0.uid, $0) })
    }

    /// Set by `--snapshot` (renders the panel to a PNG without capturing audio).
    @ObservationIgnored var isSnapshot = false

    func loadCurrentDevice() {
        deviceChanged(OutputDeviceMonitor.defaultOutputDevice())
    }

    /// A finished sample measurement for `--snapshot --page loudness --demo`.
    func applyDemoLoudness() {
        loudness = LoudnessReading(momentary: -15.8, shortTerm: -14.1, integrated: -14.5,
                                   maxMomentary: -9.5, shortTermMax: -12.9, range: 7.4, truePeak: -2.9, seconds: 154)
        loudnessRunning = true
    }

    /// Live state for `--snapshot --demo` (AirPods playing at a comfortable level).
    func applyDemo() {
        profiles = Dictionary(uniqueKeysWithValues: ((try? store.devices()) ?? []).map { ($0.uid, $0) })
        let p = DemoData.headphones
        device = OutputDevice(id: 0, uid: p.uid, name: p.name, transport: p.transport)
        volume = VolumeInfo(scalar: 0.56, decibels: -12, muted: false, hasControl: true)
        liveDBFS = -15
        liveSPL = 71
        captureState = .running
        connectedUIDs = [p.uid, DemoData.mac.uid]
    }

    var currentProfile: DeviceProfile? { device.flatMap { profiles[$0.uid] } }

    func start() {
        monitor.onChange = { [weak self] device in self?.deviceChanged(device) }
        monitor.onDevicesChange = { [weak self] in self?.refreshConnected() }
        monitor.start()

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.handleSecond(level) }
        }
        capture.loudness.onUpdate = { [weak self] reading in
            Task { @MainActor in
                guard let self, self.loudnessRunning else { return }
                self.loudness = reading
            }
        }
        capture.onStop = { [weak self] error in
            Task { @MainActor in self?.captureStopped(error) }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            },
        ]

        reloadStats()
        startCapture()
        updater.startAutomaticChecks()
    }

    // MARK: Capture & permission

    /// `force` starts the tap even when nothing is playing (so the permission prompt appears now).
    func startCapture(force: Bool = false) {
        // Show the explanation before the system prompt on first run. After that, let macOS decide:
        // CGPreflightScreenCaptureAccess() can report false while system audio capture is allowed.
        guard UserDefaults.standard.bool(forKey: "askedForAudioCapture")
                || (!usesTap && CGPreflightScreenCaptureAccess()) else {
            captureState = .needsPermission
            return
        }
        guard !capture.isRunning else { captureState = .running; return }
        guard !startInFlight else { return }   // never run two taps at once
        guard force || !playingProcesses.isEmpty else {
            captureState = .waiting
            onLiveChange?()
            return
        }
        lastPlaybackAt = Date()
        lastSoundAt = Date()   // grace period before a silence pause
        captureState = .starting
        startInFlight = true
        Task {
            defer { startInFlight = false }
            do {
                try await capture.start()
                captureState = .running
                log.info("System audio capture started")
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                let declined = (error as NSError).domain == SCStreamErrorDomain
                    && (error as NSError).code == SCStreamError.userDeclined.rawValue
                captureState = declined ? .needsPermission : .failed(error.localizedDescription)
            }
            onLiveChange?()
        }
    }

    func requestPermission() {
        UserDefaults.standard.set(true, forKey: "askedForAudioCapture")
        // The tap asks for "System Audio Recording Only" when it starts. ScreenCaptureKit shows the
        // system prompt the first time; afterwards macOS only allows it via System Settings.
        if !usesTap, !CGRequestScreenCaptureAccess() {
            openPrivacySettings()
        }
        startCapture(force: true)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        flush()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func captureStopped(_ error: Error) {
        log.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
        captureState = .failed(error.localizedDescription)
        // Typically sleep/wake or a display change; try again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.capture.isRunning else { return }
            self.startCapture()
        }
    }

    // MARK: Levels

    private func handleSecond(_ dbfs: Double?) {
        lastLevelAt = Date()
        if dbfs != nil { lastSoundAt = lastLevelAt }
        guard let dbfs, let device, let profile = profiles[device.uid] else {
            setLive(dbfs: nil, spl: nil)
            return
        }
        volume = OutputDeviceMonitor.volume(of: device.id)
        guard !volume.isSilent, let volumeDB = volume.decibels else {
            setLive(dbfs: dbfs, spl: nil)
            return
        }
        let spl = dbfs + volumeDB + profile.offset
        setLive(dbfs: dbfs, spl: spl)

        let minute = Int64(Date().timeIntervalSince1970) / 60 * 60
        pending[.init(minute: minute, uid: device.uid), default: .init()].add(db: spl)

        if verbose {
            print(String(format: "level %@ dBFS=%.1f vol=%.1fdB offset=%.1f -> %.1f dB(A)",
                         device.name, dbfs, volumeDB, profile.offset, spl))
        }
        log.debug("level \(device.name, privacy: .public) dbfs=\(dbfs) spl=\(spl)")
    }

    private func setLive(dbfs: Double?, spl: Double?) {
        liveDBFS = dbfs
        if liveSPL != spl {
            liveSPL = spl
            onLiveChange?()
        }
    }

    private func tick() {
        if let device { volume = OutputDeviceMonitor.volume(of: device.id) }
        // Touching the volume is a good hint that sound is (about to be) playing.
        if let lastVolume, lastVolume.scalar != volume.scalar || lastVolume.muted != volume.muted { wake() }
        lastVolume = volume
        followPlayback()
        // No buffers for a while: nothing is playing.
        if Date().timeIntervalSince(lastLevelAt) > 2.5, liveSPL != nil || liveDBFS != nil {
            setLive(dbfs: nil, spl: nil)
        }
    }

    /// Runs the tap only while there is something to hear, so the purple "System Audio Recording"
    /// indicator only shows while there is something to measure:
    /// - no app has audio output open: pause after 5 s;
    /// - apps have output open but the tap hears only silence for 15 s (Resolve, Teams and browsers
    ///   often keep output running silently): pause until a new app starts playing, the volume or
    ///   output device changes, or the panel is opened.
    private func followPlayback() {
        guard usesTap, !pausing, captureState.isHealthy || captureState == .starting else { return }
        let players = playingProcesses
        let names = Self.appNames(players)
        if names != listeningTo { listeningTo = names }

        // A loudness measurement needs every second of the programme, quiet parts included.
        if loudnessRunning {
            if captureState == .waiting { startCapture(force: true) }
            return
        }

        if players.isEmpty {
            silencePausedPlayers = nil
            if capture.isRunning, Date().timeIntervalSince(lastPlaybackAt) > 5 {
                pause(reason: "Nothing playing")
            }
            return
        }
        lastPlaybackAt = Date()
        if captureState == .waiting {
            if let paused = silencePausedPlayers {
                guard !players.subtracting(paused).isEmpty else { return }
                log.info("New app playing; resuming audio tap")
            }
            silencePausedPlayers = nil
            startCapture()
        } else if capture.isRunning, Date().timeIntervalSince(lastSoundAt) > 15 {
            pause(reason: "Only silence", players: players)
        }
    }

    /// Starts or resumes the loudness measurement; the tap stays on while it runs.
    func startLoudness() {
        let fresh = loudness == nil
        if fresh { loudness = .empty }
        loudnessRunning = true
        silencePausedPlayers = nil
        capture.loudness.start(reset: fresh)
        if !capture.isRunning { startCapture(force: true) }
        log.info("Loudness measurement \(fresh ? "started" : "resumed", privacy: .public)")
    }

    /// Pauses; the values so far stay on screen and resume from there.
    func stopLoudness() {
        loudnessRunning = false
        capture.loudness.pause()
        log.info("Loudness measurement paused")
    }

    /// Clears the measurement. If it was running, it keeps running from zero.
    func resetLoudness() {
        capture.loudness.reset()
        loudness = loudnessRunning ? .empty : nil
    }

    /// Resume a silence pause right away (panel opened, volume or device changed).
    func wake() {
        guard silencePausedPlayers != nil else { return }
        silencePausedPlayers = nil
        followPlayback()
    }

    private func pause(reason: String, players: Set<pid_t>? = nil) {
        pausing = true
        Task {
            await capture.stop()
            flush()
            silencePausedPlayers = players
            captureState = .waiting
            setLive(dbfs: nil, spl: nil)
            pausing = false
            log.info("\(reason, privacy: .public); audio tap paused")
            onLiveChange?()
        }
    }

    /// "Google Chrome" rather than "Google Chrome Helper (Renderer)": the outermost .app in the process path.
    private static func appNames(_ pids: Set<pid_t>) -> [String] {
        var names = Set<String>()
        for pid in pids where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
                names.insert(String(app.dropLast(4)))
            } else {
                names.insert((path as NSString).lastPathComponent)
            }
        }
        return names.sorted()
    }

    // MARK: Devices

    func refreshConnected() {
        connectedUIDs = OutputDeviceMonitor.connectedOutputUIDs()
    }

    private func deviceChanged(_ newDevice: OutputDevice?) {
        flush()
        wake()
        device = newDevice
        refreshConnected()
        if let newDevice {
            log.info("Output device: \(newDevice.name, privacy: .public) (\(newDevice.transport.label, privacy: .public))")
            if profiles[newDevice.uid] == nil {
                save(DeviceProfile.automatic(for: newDevice))
            } else if profiles[newDevice.uid]?.name != newDevice.name {
                var p = profiles[newDevice.uid]!
                p.name = newDevice.name
                save(p)
            }
            volume = OutputDeviceMonitor.volume(of: newDevice.id)
        }
        // The tap's aggregate device runs on the output device's clock, so rebuild it.
        if usesTap, capture.isRunning {
            Task {
                await capture.stop()
                startCapture()
            }
        }
        onLiveChange?()
    }

    func save(_ profile: DeviceProfile) {
        profiles[profile.uid] = profile
        do { try store.save(profile) } catch { log.error("Saving profile failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// offset = measured − (A-weighted noise level + volume in dB)
    func calibrate(measuredDB: Double, noiseDBFS: Double) -> Bool {
        guard let device, var profile = profiles[device.uid] else { return false }
        let v = OutputDeviceMonitor.volume(of: device.id)
        guard !v.isSilent, let volumeDB = v.decibels else { return false }
        profile.offset = measuredDB - (noiseDBFS + volumeDB)
        profile.calibrated = true
        save(profile)
        return true
    }

    // MARK: Persistence & stats

    func flush() {
        guard !pending.isEmpty else { return }
        let entries = pending
        pending.removeAll()
        do {
            try store.add(entries)
        } catch {
            log.error("Writing minutes failed: \(error.localizedDescription, privacy: .public)")
            for (k, v) in entries { pending[k, default: .init()].add(seconds: v.seconds, energy: v.energy) }
        }
        reloadStats()
    }

    func reloadStats() {
        do {
            summary = try store.summary(for: range)
            weeklyDose = try store.weeklyDose()
        } catch {
            log.error("Loading stats failed: \(error.localizedDescription, privacy: .public)")
        }
        checkDoseNotification()
    }

    private func checkDoseNotification() {
        let key = "notifiedWeeklyDose"
        let defaults = UserDefaults.standard
        if weeklyDose >= 1, !defaults.bool(forKey: key) {
            defaults.set(true, forKey: key)
            let content = UNMutableNotificationContent()
            content.title = "7-day listening limit reached"
            content.body = "You've reached 100% of the recommended weekly sound dose (80 dB for 40 hours). Consider turning the volume down."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly-dose", content: content, trigger: nil))
        } else if weeklyDose < 0.95 {
            defaults.set(false, forKey: key)
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Turn on launch-at-login once, when running from /Applications (not from a build folder).
    func configureLoginItemOnFirstRun() {
        let key = "configuredLoginItem"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }
}
