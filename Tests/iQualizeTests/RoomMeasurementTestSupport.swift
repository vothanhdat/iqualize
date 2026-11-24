import Foundation
@testable import iQualize

/// Shared helpers for the room measurement tests: a plain Direct-Form-II-Transposed
/// cascade stands in for the room, so the tests exercise the analysis without the
/// real-time chain's coefficient ramping.
enum RoomMeasurementTestSupport {
    static func filter(_ x: [Float], bands: [EQBand], sampleRate: Double) -> [Float] {
        var y = x.map(Double.init)
        for band in bands {
            let c = BiquadResponse.coefficients(for: band, sampleRate: sampleRate)
            let b0 = c.b0 / c.a0, b1 = c.b1 / c.a0, b2 = c.b2 / c.a0
            let a1 = c.a1 / c.a0, a2 = c.a2 / c.a0
            var z1 = 0.0, z2 = 0.0
            for i in y.indices {
                let input = y[i]
                let output = b0 * input + z1
                z1 = b1 * input - a1 * output + z2
                z2 = b2 * input - a2 * output
                y[i] = output
            }
        }
        return y.map(Float.init)
    }

    /// `signal` as a microphone would capture it: after `delay` seconds of silence, with a
    /// second of tail for the room to ring out.
    static func recording(of signal: [Float], sampleRate: Double, delay: Double, tail: Double = 1) -> [Float] {
        [Float](repeating: 0, count: Int(delay * sampleRate))
            + signal
            + [Float](repeating: 0, count: Int(tail * sampleRate))
    }

    /// Largest |curve − expected| between `lower` and `upper` Hz.
    static func maxDeviation(_ curve: FrequencyCurve, from lower: Double, to upper: Double,
                             expected: (Double) -> Double = { _ in 0 }) -> Double {
        zip(curve.frequencies, curve.dB)
            .filter { $0.0 >= lower && $0.0 <= upper }
            .map { abs($0.1 - expected($0.0)) }
            .max() ?? 0
    }
}
