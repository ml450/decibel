import AVFoundation

/// Plays looping pink noise at a known RMS level for calibration.
/// Our own audio is excluded from capture, so the level is computed here instead.
final class PinkNoisePlayer {
    static let levelDBFS = -20.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isPlaying = false
    /// A-weighted level of the generated noise in the same dBFS scale as the live meter.
    private(set) var aWeightedDBFS: Double?

    func start() throws {
        guard !isPlaying else { return }
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let noise = Self.generate(seconds: 8, sampleRate: sampleRate, dbfs: Self.levelDBFS)
        aWeightedDBFS = LevelMeter.aWeightedLevel(of: [noise], sampleRate: sampleRate)

        let frames = AVAudioFrameCount(noise.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for c in 0..<2 {
            noise.withUnsafeBufferPointer { src in
                buffer.floatChannelData![c].update(from: src.baseAddress!, count: noise.count)
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        isPlaying = true
    }

    func stop() {
        guard isPlaying else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        isPlaying = false
    }

    /// Paul Kellet's pink filter, DC removed, scaled to `dbfs` RMS, with short fades at the loop point.
    static func generate(seconds: Double, sampleRate: Double, dbfs: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        for i in 0..<n {
            let white = Double.random(in: -1...1)
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            out[i] = Float(b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362)
            b6 = white * 0.115926
        }
        let mean = out.reduce(0, +) / Float(n)
        let fade = Int(sampleRate * 0.01)
        for i in 0..<n {
            var v = out[i] - mean
            if i < fade { v *= Float(i) / Float(fade) }
            if i >= n - fade { v *= Float(n - 1 - i) / Float(fade) }
            out[i] = v
        }
        let current = LevelMeter.dbfs(of: [out])
        let gain = Float(pow(10, (dbfs - current) / 20))
        return out.map { max(-1, min(1, $0 * gain)) }
    }
}
