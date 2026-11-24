import Foundation

/// The test signal a room measurement plays. Exponential (log) sweeps spend equal time per
/// octave, so every octave gets the same energy-per-octave signal-to-noise, and deconvolving
/// one pushes the speaker's harmonic distortion to before the linear impulse response, where
/// the analysis window cuts it off (Farina, AES 2000).
struct SweepParameters: Equatable, Sendable {
    var startHz: Double
    var endHz: Double
    var duration: Double
    var sampleRate: Double
    /// Peak amplitude, capped at 0.5 (−6 dBFS) so a measurement can never play at full scale.
    var amplitude: Float
    var fadeSeconds: Double

    static let maximumAmplitude: Float = 0.5

    /// The sweep a measurement plays at `sampleRate`. It starts an octave below and ends above
    /// the 20 Hz–20 kHz analysis band (up to 0.49× the sample rate), so its fades and the
    /// analysis's band-edge tapers all sit outside it.
    static func standard(sampleRate: Double, duration: Double = 6, amplitude: Float = 0.25) -> SweepParameters {
        SweepParameters(startHz: 10, endHz: min(22000, 0.49 * sampleRate), duration: duration,
                        sampleRate: sampleRate, amplitude: amplitude, fadeSeconds: 0.05)
    }

    var frameCount: Int { Int((duration * sampleRate).rounded()) }
}

enum SweepSignal {
    /// x(t) = A·sin(2π·f1·T/R·(e^(t·R/T) − 1)), R = ln(f2/f1), with half-Hann fades at both
    /// ends to avoid clicks.
    static func sweep(_ p: SweepParameters) -> [Float] {
        let n = p.frameCount
        guard n > 1, p.startHz > 0, p.endHz > p.startHz else { return [] }
        let amplitude = Double(min(max(p.amplitude, 0), SweepParameters.maximumAmplitude))
        let T = p.duration
        let R = log(p.endHz / p.startHz)
        let k = 2 * Double.pi * p.startHz * T / R
        let fadeFrames = max(1, min(n / 2, Int(p.fadeSeconds * p.sampleRate)))

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / p.sampleRate
            var v = amplitude * sin(k * (exp(t * R / T) - 1))
            if i < fadeFrames {
                v *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeFrames))
            } else if i >= n - fadeFrames {
                v *= 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fadeFrames))
            }
            out[i] = Float(v)
        }
        return out
    }

    /// Deterministic pink noise (−3 dB/octave) whose RMS is `amplitudeDBFS`, for the level
    /// check. Paul Kellet's refined filter over a seeded white source; fades in and out over
    /// 20 ms.
    static func pinkNoise(duration: Double, sampleRate: Double, amplitudeDBFS: Float, seed: UInt64) -> [Float] {
        let n = Int((duration * sampleRate).rounded())
        guard n > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let white = rng.nextUnitDouble() * 2 - 1
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            raw[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
        }
        // Remove the DC the filter's slow poles accumulate, then scale to the requested RMS.
        let mean = raw.reduce(0, +) / Double(n)
        let rms = sqrt(raw.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n))
        let scale = rms > 0 ? pow(10, Double(amplitudeDBFS) / 20) / rms : 0
        let fadeFrames = max(1, min(n / 2, Int(0.02 * sampleRate)))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v = (raw[i] - mean) * scale
            if i < fadeFrames {
                v *= Double(i) / Double(fadeFrames)
            } else if i >= n - fadeFrames {
                v *= Double(n - 1 - i) / Double(fadeFrames)
            }
            out[i] = Float(max(-1, min(1, v)))
        }
        return out
    }
}

/// Small, fast, seedable PRNG so generated test signals are reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
