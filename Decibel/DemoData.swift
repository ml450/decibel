import Foundation

/// Sample month of listening for `--snapshot … --demo` (marketing screenshots). Uses a throwaway database.
enum DemoData {
    static let headphones = DeviceProfile(uid: "demo-airpods", name: "AirPods Pro", transport: .bluetooth,
                                          kind: .headphones, offset: 98.5, calibrated: true)
    static let mac = DeviceProfile(uid: "demo-mac", name: "MacBook Pro Speakers", transport: .builtIn,
                                   kind: .macSpeakers, offset: 80, calibrated: false)
    static let display = DeviceProfile(uid: "demo-display", name: "Studio Display", transport: .usb,
                                       kind: .externalSpeakers, offset: 85, calibrated: false)

    static func makeStore(now: Date = Date()) throws -> DecibelStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DecibelDemo-\(UUID().uuidString)")
        let store = try DecibelStore(directory: dir)
        for p in [headphones, mac, display] { try store.save(p) }

        var rng = SeededRandom(seed: 42)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var entries: [DecibelStore.MinuteKey: LevelAccumulator] = [:]

        func session(_ device: DeviceProfile, day: Date, hour: Double, minutes: Int, level: Double) {
            let start = day.addingTimeInterval(hour * 3600)
            for m in 0..<minutes {
                let t = start.addingTimeInterval(Double(m) * 60)
                guard t < now else { return }
                let key = DecibelStore.MinuteKey(minute: Int64(t.timeIntervalSince1970) / 60 * 60, uid: device.uid)
                let db = level + rng.next(in: -3...3)
                entries[key, default: .init()].add(db: db, seconds: Double(Int(rng.next(in: 40...60))))
            }
        }

        for back in 0..<31 {
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            let weekend = calendar.isDateInWeekend(day)
            // Commute and focus work on headphones; occasional loud evening.
            session(headphones, day: day, hour: 7.6, minutes: Int(rng.next(in: 25...45)), level: rng.next(in: 70...76))
            if !weekend {
                session(headphones, day: day, hour: 9.5, minutes: Int(rng.next(in: 60...150)), level: rng.next(in: 64...72))
                session(display, day: day, hour: 13.5, minutes: Int(rng.next(in: 30...90)), level: rng.next(in: 58...66))
            }
            if rng.next(in: 0...1) > 0.75 {
                session(headphones, day: day, hour: 20, minutes: Int(rng.next(in: 40...80)), level: rng.next(in: 80...86))
            }
            session(mac, day: day, hour: 17.5, minutes: Int(rng.next(in: 10...40)), level: rng.next(in: 56...64))
        }
        try store.add(entries)
        return store
    }

    /// Small deterministic generator so every snapshot looks the same.
    struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }
}
