import AppKit
import CoreGraphics
import Observation
import ScreenCaptureKit
import ServiceManagement
import UserNotifications
import os

let log = Logger(subsystem: "local.decibel.app", category: "decibel")

enum PanelPage: Equatable {
    case home, calibrate, device(String)
}

enum CaptureState: Equatable {
    case starting, needsPermission, running, failed(String)
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

    var currentProfile: DeviceProfile? { device.flatMap { profiles[$0.uid] } }

    func start() {
        monitor.onChange = { [weak self] device in self?.deviceChanged(device) }
        monitor.onDevicesChange = { [weak self] in self?.refreshConnected() }
        monitor.start()

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.handleSecond(level) }
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

    func startCapture() {
        // Show the explanation before the system prompt on first run. After that, let macOS decide:
        // CGPreflightScreenCaptureAccess() can report false while system audio capture is allowed.
        guard UserDefaults.standard.bool(forKey: "askedForAudioCapture")
                || (!usesTap && CGPreflightScreenCaptureAccess()) else {
            captureState = .needsPermission
            return
        }
        guard !capture.isRunning else { captureState = .running; return }
        captureState = .starting
        Task {
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
        startCapture()
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
        // No buffers for a while: nothing is playing.
        if Date().timeIntervalSince(lastLevelAt) > 2.5, liveSPL != nil || liveDBFS != nil {
            setLive(dbfs: nil, spl: nil)
        }
    }

    // MARK: Devices

    func refreshConnected() {
        connectedUIDs = OutputDeviceMonitor.connectedOutputUIDs()
    }

    private func deviceChanged(_ newDevice: OutputDevice?) {
        flush()
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
