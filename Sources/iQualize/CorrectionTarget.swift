import Foundation

/// The response a room correction aims for. Flat is the neutral choice; most listeners
/// prefer a little extra bass and a gentle treble roll-off in a room, which the two
/// controls add. Small speakers can't play the deepest bass at all, so the target can also
/// roll off below what the speakers reach, and the fit then leaves that region alone.
struct CorrectionTarget: Codable, Equatable, Sendable {
    /// Extra low end, as a gentle shelf centred on `bassShelfHz` (0…6 dB).
    var bassLiftDB: Double = 0
    /// Slope above `tiltPivotHz` in dB per octave (0…−1).
    var trebleTiltDBPerOctave: Double = 0
    /// The lowest frequency the speakers can usefully play: where their bass has fallen
    /// 6 dB below their midrange. Below it the target falls at 12 dB/octave, like a
    /// sealed speaker's natural roll-off, so the correction never tries to boost bass the
    /// speakers can't produce. nil = full-range speakers.
    var bassRolloffHz: Double?

    static let bassShelfHz = 120.0
    static let tiltPivotHz = 1000.0
    static let bassLiftRange: ClosedRange<Double> = 0...6
    static let trebleTiltRange: ClosedRange<Double> = -1...0
    static let bassRolloffRange: ClosedRange<Double> = 25...200
    /// Below this, only large speakers and subwoofers play usefully, and built-in or phone
    /// mics can't measure reliably — the window warns when the limit is set lower.
    static let lowBassWarningHz = 50.0
    /// The bass limit control moves in these steps (25, 30, … 200 Hz).
    static let bassRolloffStepHz = 5.0

    /// `hz` rounded to the nearest `bassRolloffStepHz`, inside `bassRolloffRange`.
    static func snappedBassRolloffHz(_ hz: Double) -> Double {
        let snapped = (hz / bassRolloffStepHz).rounded() * bassRolloffStepHz
        return min(max(snapped, bassRolloffRange.lowerBound), bassRolloffRange.upperBound)
    }

    static let flat = CorrectionTarget()

    init(bassLiftDB: Double = 0, trebleTiltDBPerOctave: Double = 0, bassRolloffHz: Double? = nil) {
        self.bassLiftDB = bassLiftDB
        self.trebleTiltDBPerOctave = trebleTiltDBPerOctave
        self.bassRolloffHz = bassRolloffHz
    }

    /// The roll-off frequency actually applied, clamped to `bassRolloffRange`.
    var effectiveBassRolloffHz: Double? {
        bassRolloffHz.map { min(max($0, Self.bassRolloffRange.lowerBound), Self.bassRolloffRange.upperBound) }
    }

    func dB(at hz: Double) -> Double {
        guard hz > 0 else { return 0 }
        let lift = min(max(bassLiftDB, Self.bassLiftRange.lowerBound), Self.bassLiftRange.upperBound)
        let tilt = min(max(trebleTiltDBPerOctave, Self.trebleTiltRange.lowerBound), Self.trebleTiltRange.upperBound)
        let ratio = hz / Self.bassShelfHz
        let shelf = lift / (1 + ratio * ratio)
        let slope = hz > Self.tiltPivotHz ? tilt * log2(hz / Self.tiltPivotHz) : 0
        return shelf + slope + rolloffDB(at: hz)
    }

    /// Second-order Butterworth high-pass placed so it is −6 dB at the roll-off frequency
    /// (−3 dB at 3^¼ ≈ 1.32× it).
    private func rolloffDB(at hz: Double) -> Double {
        guard let rolloff = effectiveBassRolloffHz else { return 0 }
        let cornerHz = rolloff * pow(3, 0.25)
        return -10 * log10(1 + pow(cornerHz / hz, 4))
    }

    func curve(on frequencies: [Double] = FrequencyCurve.standardGrid) -> FrequencyCurve {
        FrequencyCurve(frequencies: frequencies, dB: frequencies.map(dB(at:)))
    }

    // MARK: - Detecting the speakers' bass limit

    /// How far below the midrange (200 Hz–2 kHz) the bass must fall to count as the limit.
    static let rolloffDropDB = 6.0

    /// Estimates where a measured room response's bass rolls off: the highest frequency
    /// below 200 Hz where the response has fallen `rolloffDropDB` below the midrange and
    /// stays down for the octave beneath it. Room modes are averaged out first (1-octave dB
    /// average), and a dip that recovers below it — a room cancellation, not the speaker —
    /// is skipped. Returns nil for speakers that hold up to 20 Hz.
    static func estimatedBassRolloffHz(of measured: FrequencyCurve) -> Double? {
        let freqs = measured.frequencies
        guard freqs.count > 2, let reference = measured.meanDB(from: 200, to: 2000) else { return nil }
        let averaged = movingAverageDB(measured, octaves: 1)
        let threshold = reference - rolloffDropDB
        guard var i = freqs.lastIndex(where: { $0 <= 200 }) else { return nil }

        while i > 0 {
            i -= 1
            guard averaged[i] < threshold, averaged[i + 1] >= threshold else { continue }
            // Crossed downward between i and i+1: interpolate in log-frequency.
            let above = averaged[i + 1] - threshold, below = averaged[i] - threshold
            let t = above / (above - below)
            let crossing = exp(log(freqs[i + 1]) + t * (log(freqs[i]) - log(freqs[i + 1])))
            // A speaker's roll-off keeps falling; a room dip comes back up. Accept the
            // crossing only if nothing in the octave below recovers to within 3 dB of the
            // midrange's threshold.
            let octaveBelow = freqs.indices.filter { freqs[$0] >= crossing / 2 && freqs[$0] < crossing }
            if octaveBelow.allSatisfy({ averaged[$0] < threshold + 3 }) {
                return crossing < 22 ? nil : crossing
            }
        }
        return nil
    }

    /// Mean dB within ±octaves/2 of each point. Averaging decibels rather than power keeps a
    /// steady slope (a roll-off) centred where it is.
    private static func movingAverageDB(_ curve: FrequencyCurve, octaves: Double) -> [Double] {
        let freqs = curve.frequencies, values = curve.dB
        let half = pow(2, octaves / 2)
        var out = [Double](repeating: 0, count: values.count)
        var lo = 0, hi = 0, sum = 0.0
        for i in values.indices {
            while hi < values.count && freqs[hi] <= freqs[i] * half { sum += values[hi]; hi += 1 }
            while lo < hi && freqs[lo] < freqs[i] / half { sum -= values[lo]; lo += 1 }
            out[i] = sum / Double(hi - lo)
        }
        return out
    }
}
