import CoreAudio
import Foundation

/// Source of per-second A-weighted dBFS values for the system audio mix.
protocol SystemAudioSource: AnyObject {
    /// Called on a background queue once per second of audio; nil = silence.
    var onLevel: ((Double?) -> Void)? { get set }
    var onStop: ((Error) -> Void)? { get set }
    /// Loudness (LUFS) measurement fed from the same samples.
    var loudness: LoudnessFeed { get }
    var isRunning: Bool { get }
    func start() async throws
    func stop() async
}

extension SystemAudioCapture: SystemAudioSource {}

/// Reads the system audio mix through a Core Audio process tap (macOS 14.2+).
/// Needs only the "System Audio Recording Only" permission, so macOS shows no screen-sharing indicator.
/// Decibel's own process is excluded. Audio is never stored.
@available(macOS 14.2, *)
final class SystemAudioTap: SystemAudioSource {
    struct TapError: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed (OSStatus \(status))." }
    }

    var onLevel: ((Double?) -> Void)?
    var onStop: ((Error) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var meter: LevelMeter?
    let loudness: LoudnessFeed
    /// nil: everything except Decibel. Otherwise only these Core Audio process objects (one app).
    let processes: [AudioObjectID]?

    init(processes: [AudioObjectID]? = nil, loudness: LoudnessFeed = LoudnessFeed()) {
        self.processes = processes
        self.loudness = loudness
    }

    private let queue = DispatchQueue(label: "hearing.tap.audio", qos: .userInitiated)

    var isRunning: Bool { procID != nil }

    func start() async throws {
        await stop()

        let description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Decibel level meter"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap")
        tapID = tap

        do {
            guard let format: AudioStreamBasicDescription = CA.get(tap, CA.address(kAudioTapPropertyFormat)) else {
                throw TapError(step: "Reading the tap format", status: -1)
            }
            let meter = LevelMeter(sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000)
            meter.onSecond = { [weak self] level in self?.onLevel?(level) }
            self.meter = meter

            // A private aggregate device that contains only the tap. It runs on the default output's clock.
            var aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Decibel Tap",
                kAudioAggregateDeviceUIDKey: "local.decibel.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            if let output = OutputDeviceMonitor.defaultOutputDevice() {
                aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output.uid
                aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output.uid]]
            }
            var device = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "Creating the aggregate device")
            aggregateID = device

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                self?.process(input)
            }, "Creating the IO callback")
            procID = proc
            try check(AudioDeviceStart(device, proc), "Starting the tap")
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let meter else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !abl.isEmpty else { return }
        if abl.count == 1, let buf = abl.first, let data = buf.mData {
            // Interleaved
            let ptr = data.assumingMemoryBound(to: Float.self)
            let ch = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / 4 / ch
            let sample = { (c: Int, i: Int) -> Float in ptr[i * ch + c] }
            meter.process(frameCount: frames, channelCount: ch, sample: sample)
            loudness.feed(sampleRate: meter.sampleRate, frameCount: frames, channelCount: ch, sample: sample)
        } else {
            let channels: [UnsafePointer<Float>] = abl.compactMap { b in
                b.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
            }
            let frames = abl.map { Int($0.mDataByteSize) / 4 }.min() ?? 0
            let sample = { (c: Int, i: Int) -> Float in channels[c][i] }
            meter.process(frameCount: frames, channelCount: channels.count, sample: sample)
            loudness.feed(sampleRate: meter.sampleRate, frameCount: frames, channelCount: channels.count, sample: sample)
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Which processes are playing audio, from Core Audio's process objects (macOS 14.2+).
@available(macOS 14.2, *)
enum AudioActivity {
    struct Client {
        let object: AudioObjectID
        let pid: pid_t
        let playing: Bool
    }

    /// Every process registered with Core Audio except Decibel.
    static func clients() -> [Client]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = CA.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        let me = getpid()
        return ids.compactMap { id in
            guard let pid: pid_t = CA.get(id, CA.address(kAudioProcessPropertyPID)), pid != me else { return nil }
            let running: UInt32? = CA.get(id, CA.address(kAudioProcessPropertyIsRunningOutput))
            return Client(object: id, pid: pid, playing: running == 1)
        }
    }

    /// PIDs of processes other than Decibel with audio output running.
    /// If Core Audio can't tell us, report "something" rather than miss sound.
    static func playingProcesses() -> Set<pid_t> {
        guard let clients = clients() else { return [-1] }
        return Set(clients.filter(\.playing).map(\.pid))
    }

    /// "Google Chrome" rather than "Google Chrome Helper (Renderer)": the outermost .app in the process path.
    static func appName(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }
}
