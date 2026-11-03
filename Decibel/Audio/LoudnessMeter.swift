import Foundation

/// Programme loudness per ITU-R BS.1770-4 / EBU R128: K-weighted, 400 ms blocks with 75 % overlap,
/// absolute (−70 LUFS) and relative (−10 LU) gating, plus 4× oversampled true peak.
/// Measured on the digital signal, before the system volume.
final class LoudnessMeter {
    let sampleRate: Double
    /// Called on the audio queue every 100 ms.
    var onUpdate: ((LoudnessReading) -> Void)?

    private let template: [Biquad]
    private var filters: [[Biquad]] = []
    private var peakers: [TruePeakOversampler] = []
    private let hopFrames: Int
    private var hopSums: [Double] = []
    private var framesInHop = 0
    private var totalFrames = 0

    private var recentHops: [Double] = []        // last 30 × 100 ms (channel-summed mean squares)
    private var blocks: [Double] = []            // every 400 ms block, for the integrated value
    private var shortTermPowers: [Double] = []   // every 3 s window, for loudness range
    private var maxMomentary = -Double.infinity
    private var maxShortTerm = -Double.infinity
    private var range: Double?
    private var peak = 0.0
    private var integrated: Double?
    private var hopsSinceIntegrated = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.hopFrames = max(1, Int((sampleRate / 10).rounded()))
        self.template = Self.kWeighting(sampleRate: sampleRate)
    }

    func process(frameCount: Int, channelCount: Int, sample: (Int, Int) -> Float) {
        guard frameCount > 0, channelCount > 0 else { return }
        if filters.count != channelCount {
            filters = Array(repeating: template, count: channelCount)
            peakers = Array(repeating: TruePeakOversampler(), count: channelCount)
            hopSums = Array(repeating: 0, count: channelCount)
        }
        for i in 0..<frameCount {
            for c in 0..<channelCount {
                let x = Double(sample(c, i))
                peak = max(peak, peakers[c].process(x))
                var y = x
                for k in 0..<filters[c].count { y = filters[c][k].process(y) }
                hopSums[c] += y * y
            }
            framesInHop += 1
            totalFrames += 1
            if framesInHop == hopFrames { finishHop() }
        }
    }

    private func finishHop() {
        // Channel weights are 1.0 for L/R (the only channels we capture).
        let power = hopSums.reduce(0, +) / Double(hopFrames)
        for c in hopSums.indices { hopSums[c] = 0 }
        framesInHop = 0

        recentHops.append(power)
        if recentHops.count > 30 { recentHops.removeFirst(recentHops.count - 30) }

        var momentary: Double?
        if recentHops.count >= 4 {
            let block = recentHops.suffix(4).reduce(0, +) / 4
            blocks.append(block)
            momentary = Self.lufs(block)
            maxMomentary = max(maxMomentary, momentary ?? -.infinity)
        }
        var shortTerm: Double?
        if recentHops.count >= 30 {
            let power = recentHops.reduce(0, +) / 30
            shortTermPowers.append(power)
            shortTerm = Self.lufs(power)
            maxShortTerm = max(maxShortTerm, shortTerm ?? -.infinity)
        }

        hopsSinceIntegrated += 1
        if hopsSinceIntegrated >= 5 {
            hopsSinceIntegrated = 0
            integrated = Self.gatedLoudness(blocks)
            range = Self.loudnessRange(shortTermPowers)
        }

        onUpdate?(LoudnessReading(
            momentary: momentary.flatMap(Self.finite),
            shortTerm: shortTerm.flatMap(Self.finite),
            integrated: integrated,
            maxMomentary: Self.finite(maxMomentary),
            shortTermMax: Self.finite(maxShortTerm),
            range: range,
            truePeak: peak > 0 ? 20 * log10(peak) : nil,
            seconds: Double(totalFrames) / sampleRate))
    }

    /// Final value right now (also used by the self-test).
    var integratedNow: Double? { Self.gatedLoudness(blocks) }
    var truePeakNow: Double? { peak > 0 ? 20 * log10(peak) : nil }
    var rangeNow: Double? { Self.loudnessRange(shortTermPowers) }

    // MARK: Maths

    static func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }

    private static func finite(_ v: Double) -> Double? { v.isFinite ? v : nil }

    static func gatedLoudness(_ blocks: [Double]) -> Double? {
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Loudness range (EBU Tech 3342): spread between the 10th and 95th percentile of the
    /// short-term loudness, after a −70 LUFS absolute and −20 LU relative gate.
    static func loudnessRange(_ shortTerm: [Double]) -> Double? {
        let absolute = shortTerm.filter { lufs($0) > -70 }
        guard absolute.count >= 2 else { return nil }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 20
        let values = absolute.map(lufs).filter { $0 > relativeGate }.sorted()
        guard values.count >= 2 else { return nil }
        func percentile(_ p: Double) -> Double { values[min(values.count - 1, Int((p * Double(values.count - 1)).rounded()))] }
        return percentile(0.95) - percentile(0.10)
    }

    /// BS.1770 K-weighting (high shelf + RLB high-pass), derived for any sample rate.
    static func kWeighting(sampleRate fs: Double) -> [Biquad] {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let gain = 3.999843853973347
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444; q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return [shelf, highPass]
    }
}

struct LoudnessReading: Equatable {
    var momentary: Double?
    var shortTerm: Double?
    var integrated: Double?
    var maxMomentary: Double?
    var shortTermMax: Double? = nil
    var range: Double? = nil
    var truePeak: Double?
    var seconds: Double

    static let empty = LoudnessReading(seconds: 0)
}

/// 4× oversampling interpolator (48-tap windowed sinc) for true-peak detection.
struct TruePeakOversampler {
    private static let factor = 4
    private static let tapsPerPhase = 12
    private static let taps: [Double] = {
        let n = factor * tapsPerPhase
        let centre = Double(n - 1) / 2
        var h = (0..<n).map { i -> Double in
            let t = (Double(i) - centre) / Double(factor)
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
                + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))   // Blackman
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 * Double(factor) / sum }
        return h
    }()

    private var history = [Double](repeating: 0, count: tapsPerPhase)
    private var position = 0

    /// Largest absolute value among the input sample and its 4 interpolated neighbours.
    mutating func process(_ x: Double) -> Double {
        history[position] = x
        var m = abs(x)
        for phase in 0..<Self.factor {
            var acc = 0.0
            for k in 0..<Self.tapsPerPhase {
                acc += Self.taps[phase + Self.factor * k] * history[(position - k + Self.tapsPerPhase) % Self.tapsPerPhase]
            }
            m = max(m, abs(acc))
        }
        position = (position + 1) % Self.tapsPerPhase
        return m
    }
}

/// Delivery targets for the loudness meter.
enum LoudnessTarget: String, CaseIterable, Identifiable {
    case streaming = "youtube", appleMusic, broadcast

    var id: String { rawValue }

    var lufs: Double {
        switch self {
        case .streaming: -14
        case .appleMusic: -16
        case .broadcast: -23
        }
    }

    /// Who will turn it down, for the verdict sentence.
    var name: String {
        switch self {
        case .streaming: "YouTube"
        case .appleMusic: "Apple Music"
        case .broadcast: "Broadcast"
        }
    }

    var label: String {
        switch self {
        case .streaming: "−14 LUFS · YouTube, Spotify, social"
        case .appleMusic: "−16 LUFS · Apple Music"
        case .broadcast: "−23 LUFS · Broadcast (EBU R128)"
        }
    }
}

/// Lets a capture feed a loudness measurement that the app starts, pauses and resets from the main thread.
final class LoudnessFeed {
    /// Called on the audio queue every 100 ms while measuring.
    var onUpdate: ((LoudnessReading) -> Void)?

    private let lock = NSLock()
    private var enabled = false
    private var resetRequested = false
    private var meter: LoudnessMeter?   // audio queue only

    /// Starts (or resumes) measuring; `reset` throws away what was measured so far.
    func start(reset: Bool) {
        lock.lock(); enabled = true; if reset { resetRequested = true }; lock.unlock()
    }

    /// Pauses; the measurement so far is kept until the next reset.
    func pause() {
        lock.lock(); enabled = false; lock.unlock()
    }

    func reset() {
        lock.lock(); resetRequested = true; lock.unlock()
    }

    /// Audio queue: forward the same samples the level meter sees.
    func feed(sampleRate: Double, frameCount: Int, channelCount: Int, sample: (Int, Int) -> Float) {
        lock.lock()
        let on = enabled, reset = resetRequested
        if on { resetRequested = false }
        lock.unlock()
        guard on else { return }
        if reset || meter?.sampleRate != sampleRate {
            let m = LoudnessMeter(sampleRate: sampleRate)
            m.onUpdate = { [weak self] reading in self?.onUpdate?(reading) }
            meter = m
        }
        meter?.process(frameCount: frameCount, channelCount: channelCount, sample: sample)
    }
}
