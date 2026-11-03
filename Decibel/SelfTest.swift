import Foundation

/// `Decibel.app/Contents/MacOS/Decibel --selftest` exercises the measurement → estimate → storage → dose
/// pipeline with synthetic audio and a throwaway database, then exits 0 (pass) or 1 (fail).
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            if !ok { failures += 1 }
        }
        func sine(_ f: Double, amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
            (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * f * Double($0) / sampleRate)) }
        }
        let sr = 48_000.0

        // 1. A-weighting response vs IEC 61672 nominal values, within Class 1 tolerance
        for (f, expected, tolerance) in [(31.5, -39.4, 1.5), (100.0, -19.1, 1.0), (1000.0, 0.0, 0.7),
                                          (4000.0, 1.0, 1.0), (10000.0, -2.5, 2.0)] {
            let s = sine(f, amplitude: 0.5, seconds: 2, sampleRate: sr)
            let gain = LevelMeter.aWeightedLevel(of: [s], sampleRate: sr) - LevelMeter.dbfs(of: [s])
            check("A-weighting \(Int(f)) Hz", abs(gain - expected) <= tolerance,
                  String(format: "%.2f dB (nominal %.1f ± %.1f)", gain, expected, tolerance))
        }

        // 2. Per-second meter, silence floor
        let meter = LevelMeter(sampleRate: sr)
        var levels: [Double?] = []
        meter.onSecond = { levels.append($0) }
        let loud = sine(1000, amplitude: 0.1, seconds: 3, sampleRate: sr)          // −23.0 dBFS
        let quiet = sine(1000, amplitude: 0.0004, seconds: 1, sampleRate: sr)      // −71 dBFS
        let silence = [Float](repeating: 0, count: Int(sr))
        for signal in [loud, silence, quiet] {
            var i = 0
            while i < signal.count {                       // feed in 1024-frame stereo buffers
                let n = min(1024, signal.count - i)
                let base = i
                meter.process(frameCount: n, channelCount: 2) { _, j in signal[base + j] }
                i += n
            }
        }
        check("meter emits once per second", levels.count == 5, "\(levels.count) values")
        let first = levels.prefix(3).compactMap { $0 }
        check("meter level (1 kHz, −23.0 dBFS)", first.count == 3 && first.allSatisfy { abs($0 + 23.0) < 0.3 },
              first.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        check("silence ignored (< −60 dBFS)", levels.count == 5 && levels[3] == nil && levels[4] == nil,
              "digital silence and −71 dBFS → nil")

        // 3. Estimate
        let profile = DeviceProfile.automatic(for: OutputDevice(id: 0, uid: "test-airpods", name: "AirPods Pro", transport: .bluetooth))
        check("AirPods default profile", profile.kind == .headphones && profile.offset == 100, "\(profile.kind.label), \(profile.offset) dB")
        let mac = DeviceProfile.automatic(for: OutputDevice(id: 0, uid: "mac", name: "MacBook Pro Speakers", transport: .builtIn))
        check("Mac speakers default profile", mac.kind == .macSpeakers && mac.offset == 80, "\(mac.kind.label), \(mac.offset) dB")
        let xm5 = DeviceProfile.automatic(for: OutputDevice(id: 0, uid: "xm5", name: "WH-1000XM5", transport: .bluetooth))
        check("XM5 default profile", xm5.kind == .headphones && xm5.offset == 100, "\(xm5.kind.label), \(xm5.offset) dB")
        let spl = -23.0 + (-10.0) + profile.offset
        check("SPL = dBFS + volume dB + offset", abs(spl - 67) < 0.001, "−23 + −10 + 100 = \(spl)")

        // 4. Dose maths
        check("dose 80 dB × 40 h = 100%", abs(Dose.fraction(seconds: 40 * 3600, db: 80) - 1) < 1e-9, "")
        check("dose 83 dB × 20 h = 100%", abs(Dose.fraction(seconds: 20 * 3600, db: 83) - 1) < 1e-9, "")
        check("dose 90 dB × 4 h ≈ 100%", abs(Dose.fraction(seconds: 4 * 3600, db: 90) - 1) < 0.01,
              String(format: "%.3f", Dose.fraction(seconds: 4 * 3600, db: 90)))

        // 5. Storage round-trip
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DecibelSelfTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try DecibelStore(directory: dir)
            try store.save(profile)
            try store.save(mac)
            check("profiles persisted", try store.devices().count == 2, "")

            let now = Date()
            let m0 = Int64(now.timeIntervalSince1970) / 60 * 60 - 600
            var batch1: [DecibelStore.MinuteKey: LevelAccumulator] = [:]
            for _ in 0..<60 { batch1[.init(minute: m0, uid: profile.uid), default: .init()].add(db: 70) }
            for _ in 0..<20 { batch1[.init(minute: m0 + 60, uid: profile.uid), default: .init()].add(db: 70) }
            for _ in 0..<60 { batch1[.init(minute: m0, uid: mac.uid), default: .init()].add(db: 90) }
            try store.add(batch1)
            // A second flush into the same (partial) minute must accumulate, not overwrite.
            var batch2: [DecibelStore.MinuteKey: LevelAccumulator] = [:]
            for _ in 0..<10 { batch2[.init(minute: m0 + 60, uid: profile.uid), default: .init()].add(db: 70) }
            try store.add(batch2)

            let s = try store.summary(for: .week, now: now)
            check("total seconds", s.seconds == 150, "\(s.seconds) s")
            let a = s.devices[profile.uid], b = s.devices[mac.uid]
            check("per-device time & level", a?.seconds == 90 && abs((a?.avgDB ?? 0) - 70) < 0.01
                  && b?.seconds == 60 && abs((b?.avgDB ?? 0) - 90) < 0.01,
                  String(format: "AirPods %.0f s @ %.1f dB, Mac %.0f s @ %.1f dB", a?.seconds ?? 0, a?.avgDB ?? 0, b?.seconds ?? 0, b?.avgDB ?? 0))
            let expectedLeq = 10 * log10((90 * 1e7 + 60 * 1e9) / 150)
            check("range average is energy-based (Leq)", abs((s.avgDB ?? 0) - expectedLeq) < 0.01,
                  String(format: "%.2f dB (expected %.2f)", s.avgDB ?? 0, expectedLeq))
            check("daily buckets", !s.buckets.isEmpty && s.buckets.reduce(0) { $0 + $1.seconds } == 150, "\(s.buckets.count) bucket(s)")
            let dose = try store.weeklyDose(now: now)
            let expectedDose = Dose.fraction(seconds: 90, db: 70) + Dose.fraction(seconds: 60, db: 90)
            check("rolling 7-day dose", abs(dose - expectedDose) < 1e-9, String(format: "%.4f%%", dose * 100))
        } catch {
            check("storage", false, error.localizedDescription)
        }

        // 6. Calibration noise
        let noise = PinkNoisePlayer.generate(seconds: 4, sampleRate: sr, dbfs: PinkNoisePlayer.levelDBFS)
        let raw = LevelMeter.dbfs(of: [noise])
        let weighted = LevelMeter.aWeightedLevel(of: [noise], sampleRate: sr)
        check("pink noise at −20 dBFS", abs(raw + 20) < 0.05, String(format: "%.2f dBFS, A-weighted %.2f dBFS", raw, weighted))
        // With 75 dB measured at −12 dB volume, the stored offset must reproduce 75 dB.
        let offset = 75 - (weighted + -12)
        check("calibration offset round-trip", abs((weighted - 12 + offset) - 75) < 1e-9, String(format: "offset %.1f dB", offset))

        // 7. Loudness (EBU Tech 3341 reference cases)
        func loudness(_ parts: [(dbfs: Double, seconds: Double)], frequency: Double = 1000, phase: Double = 0) -> LoudnessMeter {
            let meter = LoudnessMeter(sampleRate: sr)
            for part in parts {
                let amp = pow(10, part.dbfs / 20)
                let n = Int(part.seconds * sr)
                var i = 0
                while i < n {
                    let count = min(4800, n - i)
                    let base = i
                    meter.process(frameCount: count, channelCount: 2) { _, j in
                        Float(amp * sin(2 * .pi * frequency * Double(base + j) / sr + phase))
                    }
                    i += count
                }
            }
            return meter
        }
        let ebu1 = loudness([(-23, 20)])
        check("LUFS: stereo 1 kHz at −23 dBFS = −23 LUFS", abs((ebu1.integratedNow ?? 0) + 23) < 0.1,
              String(format: "%.2f LUFS", ebu1.integratedNow ?? .nan))
        let ebu3 = loudness([(-36, 10), (-23, 60), (-36, 10)])
        check("LUFS: gating (−36/−23/−36) = −23 LUFS", abs((ebu3.integratedNow ?? 0) + 23) < 0.1,
              String(format: "%.2f LUFS", ebu3.integratedNow ?? .nan))
        let silent = loudness([(-80, 5)])
        check("LUFS: below −70 is gated out", silent.integratedNow == nil, "nil")
        let lra = loudness([(-20, 20), (-30, 20)])
        check("loudness range (−20/−30) ≈ 10 LU", abs((lra.rangeNow ?? 0) - 10) < 1,
              String(format: "%.1f LU", lra.rangeNow ?? .nan))
        // fs/4 sine at 45°: samples only reach −3 dB of the true peak.
        let tp = loudness([(-6.02, 2)], frequency: sr / 4, phase: .pi / 4)
        check("true peak finds inter-sample peaks", abs((tp.truePeakNow ?? 0) + 6.02) < 0.3,
              String(format: "%.2f dBTP (sample peak −9.03)", tp.truePeakNow ?? .nan))

        // 8. Update version comparison
        check("update versions", Updater.isNewer("1.1", than: "1.0") && Updater.isNewer("1.0.1", than: "1.0")
              && Updater.isNewer("1.10", than: "1.9") && !Updater.isNewer("1.0", than: "1.0.0")
              && !Updater.isNewer("0.9", than: "1.0"), "1.1 > 1.0, 1.0.1 > 1.0, 1.10 > 1.9, 1.0 = 1.0.0")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0
    }
}
