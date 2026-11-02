import Foundation

/// Accumulates A-weighted power and emits one dBFS value per second of audio.
/// dBFS here is 10·log10(mean square), i.e. a full-scale square wave is 0 dBFS.
/// Values below `floorDBFS` are reported as nil (silence).
final class LevelMeter {
    let sampleRate: Double
    let floorDBFS: Double
    var onSecond: ((Double?) -> Void)?

    private let template: [Biquad]
    private var filters: [[Biquad]] = []
    private let windowFrames: Int
    private var sum = 0.0
    private var samples = 0
    private var frames = 0

    init(sampleRate: Double, floorDBFS: Double = -60) {
        self.sampleRate = sampleRate
        self.floorDBFS = floorDBFS
        self.windowFrames = max(1, Int(sampleRate.rounded()))
        self.template = AWeighting.sections(sampleRate: sampleRate)
    }

    /// `sample(channel, frame)` returns the raw sample value.
    func process(frameCount: Int, channelCount: Int, sample: (Int, Int) -> Float) {
        guard frameCount > 0, channelCount > 0 else { return }
        if filters.count != channelCount {
            filters = Array(repeating: template, count: channelCount)
        }
        var offset = 0
        while offset < frameCount {
            let chunk = min(frameCount - offset, windowFrames - frames)
            for c in 0..<channelCount {
                var f = filters[c]
                var s = 0.0
                for i in offset..<(offset + chunk) {
                    var x = Double(sample(c, i))
                    for k in 0..<f.count { x = f[k].process(x) }
                    s += x * x
                }
                filters[c] = f
                sum += s
            }
            samples += chunk * channelCount
            frames += chunk
            offset += chunk
            if frames >= windowFrames { emit() }
        }
    }

    private func emit() {
        let ms = samples > 0 ? sum / Double(samples) : 0
        let db = ms > 0 ? 10 * log10(ms) : -Double.infinity
        sum = 0; samples = 0; frames = 0
        onSecond?(db >= floorDBFS ? db : nil)
    }

    /// A-weighted level of a whole signal (first 0.25 s skipped to let the filters settle).
    static func aWeightedLevel(of channels: [[Float]], sampleRate: Double) -> Double {
        let sections = AWeighting.sections(sampleRate: sampleRate)
        let skip = Int(sampleRate * 0.25)
        var sum = 0.0, n = 0
        for channel in channels {
            var f = sections
            for (i, v) in channel.enumerated() {
                var x = Double(v)
                for k in 0..<f.count { x = f[k].process(x) }
                if i >= skip { sum += x * x; n += 1 }
            }
        }
        return n > 0 && sum > 0 ? 10 * log10(sum / Double(n)) : -Double.infinity
    }

    static func dbfs(of channels: [[Float]]) -> Double {
        var sum = 0.0, n = 0
        for ch in channels { for v in ch { sum += Double(v) * Double(v); n += 1 } }
        return n > 0 && sum > 0 ? 10 * log10(sum / Double(n)) : -Double.infinity
    }
}
