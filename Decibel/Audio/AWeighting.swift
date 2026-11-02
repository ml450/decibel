import Foundation

/// Transposed direct-form II biquad.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Complex response at normalised angular frequency w (radians/sample).
    func response(at w: Double) -> (re: Double, im: Double) {
        // H = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let c1 = cos(w), s1 = -sin(w), c2 = cos(2 * w), s2 = -sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
        let den = dr * dr + di * di
        return ((nr * dr + ni * di) / den, (ni * dr - nr * di) / den)
    }
}

/// IEC 61672 A-weighting as three biquads (bilinear transform with pre-warped poles),
/// normalised to 0 dB at 1 kHz.
enum AWeighting {
    static func sections(sampleRate fs: Double) -> [Biquad] {
        let k = 2 * fs
        // Pre-warp so the digital poles land on the analog pole frequencies.
        func w(_ f: Double) -> Double { 2 * fs * tan(Double.pi * min(f, fs * 0.49) / fs) }
        let w1 = w(20.598997), w2 = w(107.65265), w3 = w(737.86223), w4 = w(12194.217)

        // (s + wp) -> ((k + wp) + (wp - k) z^-1) / (1 + z^-1)
        func pole(_ wp: Double) -> (Double, Double) { (k + wp, wp - k) }
        func mul(_ p: (Double, Double), _ q: (Double, Double)) -> (Double, Double, Double) {
            (p.0 * q.0, p.0 * q.1 + p.1 * q.0, p.1 * q.1)
        }
        func biquad(_ num: (Double, Double, Double), _ den: (Double, Double, Double)) -> Biquad {
            Biquad(b0: num.0 / den.0, b1: num.1 / den.0, b2: num.2 / den.0,
                   a1: den.1 / den.0, a2: den.2 / den.0)
        }

        let s2 = (k * k, -2 * k * k, k * k)   // s^2 -> k^2 (1 - z^-1)^2 / (1 + z^-1)^2
        let lp = (1.0, 2.0, 1.0)               // (1 + z^-1)^2

        var sections = [
            biquad(s2, mul(pole(w1), pole(w1))),   // s^2 / (s + w1)^2
            biquad(s2, mul(pole(w2), pole(w3))),   // s^2 / ((s + w2)(s + w3))
            biquad(lp, mul(pole(w4), pole(w4))),   // 1 / (s + w4)^2
        ]

        let gain = magnitude(of: sections, at: 1000, sampleRate: fs)
        sections[0].b0 /= gain; sections[0].b1 /= gain; sections[0].b2 /= gain
        return sections
    }

    static func magnitude(of sections: [Biquad], at frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * frequency / fs
        var re = 1.0, im = 0.0
        for s in sections {
            let h = s.response(at: w)
            (re, im) = (re * h.re - im * h.im, re * h.im + im * h.re)
        }
        return (re * re + im * im).squareRoot()
    }
}
