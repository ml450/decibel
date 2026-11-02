import Foundation

enum DeviceKind: String, CaseIterable, Identifiable {
    case macSpeakers, headphones, externalSpeakers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .macSpeakers: "Mac speakers"
        case .headphones: "Headphones"
        case .externalSpeakers: "External speakers"
        }
    }

    /// Estimated dB(A) SPL for a 0 dBFS signal at maximum volume.
    var defaultOffset: Double {
        switch self {
        case .macSpeakers: 80      // MacBook speakers at ~50 cm
        case .headphones: 100      // AirPods / Sony WH-1000XM5 class
        case .externalSpeakers: 85 // unknown speakers
        }
    }

    var symbol: String {
        switch self {
        case .macSpeakers: "laptopcomputer"
        case .headphones: "headphones"
        case .externalSpeakers: "hifispeaker.fill"
        }
    }
}

struct DeviceProfile: Identifiable, Equatable {
    var uid: String
    var name: String
    var transport: Transport
    var kind: DeviceKind
    var offset: Double
    var calibrated: Bool

    var id: String { uid }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        return kind.symbol
    }

    static func automatic(for device: OutputDevice) -> DeviceProfile {
        let kind = guessKind(name: device.name, transport: device.transport)
        return DeviceProfile(uid: device.uid, name: device.name, transport: device.transport,
                             kind: kind, offset: kind.defaultOffset, calibrated: false)
    }

    static func guessKind(name: String, transport: Transport) -> DeviceKind {
        let n = name.lowercased()
        let headphoneHints = ["airpods", "headphone", "headset", "earbuds", "buds", "beats", "powerbeats",
                              "wh-1000", "wf-1000", "xm3", "xm4", "xm5", "xm6", "quietcomfort", "bose qc",
                              "momentum", "sennheiser", "jabra", "earphone"]
        if headphoneHints.contains(where: n.contains) { return .headphones }
        if transport == .builtIn { return .macSpeakers }
        return .externalSpeakers
    }
}

/// Energy accumulator: Leq = 10·log10(Σ t·10^(L/10) / Σ t).
struct LevelAccumulator {
    var seconds = 0.0
    var energy = 0.0

    mutating func add(db: Double, seconds s: Double = 1) {
        seconds += s
        energy += s * pow(10, db / 10)
    }

    mutating func add(seconds s: Double, energy e: Double) {
        seconds += s
        energy += e
    }

    var leq: Double? { seconds > 0 && energy > 0 ? 10 * log10(energy / seconds) : nil }
}

enum Dose {
    static let referenceDB = 80.0
    static let referenceSeconds = 40.0 * 3600
    static let exchangeRate = 3.0

    /// Fraction of the weekly allowance used by `seconds` at `db` dB(A).
    static func fraction(seconds: Double, db: Double) -> Double {
        seconds / (referenceSeconds * pow(2, (referenceDB - db) / exchangeRate))
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case day = "D", week = "W", month = "M", sixMonths = "6M", year = "Y"

    var id: String { rawValue }

    /// D shows hours; every other range shows one bar per day.
    var bucket: Calendar.Component { self == .day ? .hour : .day }

    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        if self == .week {
            // Calendar week, Monday to Sunday (future days show as empty tracks).
            var monday = calendar
            monday.firstWeekday = 2
            let week = monday.dateInterval(of: .weekOfYear, for: now)!
            return DateInterval(start: week.start, end: week.end)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let start: Date
        switch self {
        case .day, .week: start = today
        case .month: start = calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .month, value: -1, to: today)!)!
        case .sixMonths: start = calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .month, value: -6, to: today)!)!
        case .year: start = calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .year, value: -1, to: today)!)!
        }
        return DateInterval(start: start, end: end)
    }
}

struct Bucket: Identifiable {
    let start: Date
    let seconds: Double
    let avgDB: Double
    var id: Date { start }
}

struct DeviceUsage {
    let seconds: Double
    let avgDB: Double
}

struct RangeSummary {
    var interval: DateInterval
    var seconds: Double
    var avgDB: Double?
    var buckets: [Bucket]
    var devices: [String: DeviceUsage]

    static let empty = RangeSummary(interval: DateInterval(), seconds: 0, avgDB: nil, buckets: [], devices: [:])
}
