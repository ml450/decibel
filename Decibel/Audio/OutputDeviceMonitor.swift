import CoreAudio
import Foundation

enum Transport: String {
    case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate, other

    init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .airPlay: "AirPlay"
        case .thunderbolt: "Thunderbolt"
        case .virtual: "Virtual"
        case .aggregate: "Aggregate"
        case .other: "Other"
        }
    }
}

struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: Transport
}

struct VolumeInfo: Equatable {
    /// 0…1 as shown by the system volume slider.
    var scalar: Double
    /// Attenuation relative to the device's maximum (≤ 0). nil when the volume is at zero.
    var decibels: Double?
    var muted: Bool
    var hasControl: Bool

    static let unity = VolumeInfo(scalar: 1, decibels: 0, muted: false, hasControl: false)
    var isSilent: Bool { muted || decibels == nil }
}

/// Follows the system default output device.
final class OutputDeviceMonitor {
    var onChange: ((OutputDevice?) -> Void)?
    /// Called when output devices are connected or disconnected.
    var onDevicesChange: (() -> Void)?
    private(set) var current: OutputDevice?
    private var listeners: [AudioObjectPropertyListenerBlock] = []

    func start() {
        var address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)

        var devices = CA.address(kAudioHardwarePropertyDevices)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDevicesChange?() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, devicesBlock)

        listeners = [block, devicesBlock]
        refresh()
    }

    /// UIDs of every device that can currently play audio.
    static func connectedOutputUIDs() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = CA.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids.compactMap { id -> String? in
            var streams = CA.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            return CA.string(id, kAudioDevicePropertyDeviceUID)
        })
    }

    func refresh() {
        let device = Self.defaultOutputDevice()
        guard device != current else { return }
        current = device
        onChange?(device)
    }

    static func defaultOutputDevice() -> OutputDevice? {
        guard let id: AudioDeviceID = CA.get(AudioObjectID(kAudioObjectSystemObject),
                                             CA.address(kAudioHardwarePropertyDefaultOutputDevice)),
              id != kAudioObjectUnknown
        else { return nil }
        let uid = CA.string(id, kAudioDevicePropertyDeviceUID) ?? "device-\(id)"
        let name = CA.string(id, kAudioObjectPropertyName) ?? "Unknown Output"
        let transport: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyTransportType)) ?? 0
        return OutputDevice(id: id, uid: uid, name: name, transport: Transport(code: transport))
    }

    static func volume(of id: AudioDeviceID) -> VolumeInfo {
        let scope = kAudioDevicePropertyScopeOutput
        let muted = isMuted(id)

        func has(_ element: AudioObjectPropertyElement) -> Bool {
            var a = CA.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            return AudioObjectHasProperty(id, &a)
        }
        let elements: [AudioObjectPropertyElement] =
            has(kAudioObjectPropertyElementMain) ? [kAudioObjectPropertyElementMain] : [1, 2].filter(has)
        guard !elements.isEmpty else {
            // Fixed-level outputs (HDMI, some USB DACs): treat as full volume.
            return VolumeInfo(scalar: 1, decibels: 0, muted: muted, hasControl: false)
        }

        var scalars: [Double] = []
        var dbs: [Double] = []
        for element in elements {
            guard let s: Float32 = CA.get(id, CA.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element))
            else { continue }
            scalars.append(Double(s))
            if let db = decibels(id, scalar: s, element: element) { dbs.append(db) }
        }
        guard !scalars.isEmpty else { return VolumeInfo(scalar: 1, decibels: 0, muted: muted, hasControl: false) }

        let scalar = scalars.max() ?? 1
        let decibels: Double?
        if scalar < 0.0001 {
            decibels = nil
        } else if dbs.count == scalars.count, let loudest = dbs.max() {
            decibels = min(0, loudest)
        } else {
            decibels = 20 * log10(scalar)
        }
        return VolumeInfo(scalar: scalar, decibels: decibels, muted: muted, hasControl: true)
    }

    /// Uses the device's own volume curve to convert the slider position into dB below maximum.
    private static func decibels(_ id: AudioDeviceID, scalar: Float32, element: AudioObjectPropertyElement) -> Double? {
        let scope = kAudioDevicePropertyScopeOutput
        var a = CA.address(kAudioDevicePropertyVolumeScalarToDecibels, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var value = scalar
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
        let range: AudioValueRange? = CA.get(id, CA.address(kAudioDevicePropertyVolumeRangeDecibels, scope: scope, element: element))
        return Double(value) - (range?.mMaximum ?? 0)
    }

    private static func isMuted(_ id: AudioDeviceID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1] {
            if let m: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)) {
                return m != 0
            }
        }
        return false
    }
}

/// Small CoreAudio property helpers.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var a = address
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.load(as: T.self)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
