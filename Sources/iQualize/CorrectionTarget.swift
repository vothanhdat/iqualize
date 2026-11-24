import Foundation

/// The response a room correction aims for. Flat is the neutral choice; most listeners
/// prefer a little extra bass and a gentle treble roll-off in a room, which the two
/// controls add.
struct CorrectionTarget: Codable, Equatable, Sendable {
    /// Extra low end, as a gentle shelf centred on `bassShelfHz` (0…6 dB).
    var bassLiftDB: Double = 0
    /// Slope above `tiltPivotHz` in dB per octave (0…−1).
    var trebleTiltDBPerOctave: Double = 0

    static let bassShelfHz = 120.0
    static let tiltPivotHz = 1000.0
    static let bassLiftRange: ClosedRange<Double> = 0...6
    static let trebleTiltRange: ClosedRange<Double> = -1...0

    static let flat = CorrectionTarget()

    func dB(at hz: Double) -> Double {
        guard hz > 0 else { return 0 }
        let lift = min(max(bassLiftDB, Self.bassLiftRange.lowerBound), Self.bassLiftRange.upperBound)
        let tilt = min(max(trebleTiltDBPerOctave, Self.trebleTiltRange.lowerBound), Self.trebleTiltRange.upperBound)
        let ratio = hz / Self.bassShelfHz
        let shelf = lift / (1 + ratio * ratio)
        let slope = hz > Self.tiltPivotHz ? tilt * log2(hz / Self.tiltPivotHz) : 0
        return shelf + slope
    }

    func curve(on frequencies: [Double] = FrequencyCurve.standardGrid) -> FrequencyCurve {
        FrequencyCurve(frequencies: frequencies, dB: frequencies.map(dB(at:)))
    }
}
