import Foundation

/// A magnitude response in dB sampled at increasing frequencies — a measurement, a target,
/// a correction, or a prediction. The room correction pipeline keeps every curve on
/// `standardGrid` so they can be combined point by point.
struct FrequencyCurve: Codable, Equatable, Sendable {
    var frequencies: [Double]
    var dB: [Double]

    init(frequencies: [Double], dB: [Double]) {
        precondition(frequencies.count == dB.count, "FrequencyCurve needs one dB value per frequency")
        self.frequencies = frequencies
        self.dB = dB
    }

    private enum CodingKeys: String, CodingKey { case frequencies, dB }

    /// Rejects a persisted curve whose arrays don't pair up, rather than trapping later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frequencies = try c.decode([Double].self, forKey: .frequencies)
        let dB = try c.decode([Double].self, forKey: .dB)
        guard frequencies.count == dB.count else {
            throw DecodingError.dataCorruptedError(forKey: .dB, in: c,
                                                   debugDescription: "frequencies and dB differ in length")
        }
        self.frequencies = frequencies
        self.dB = dB
    }

    /// Log spacing from exactly 20 Hz to exactly 20 kHz at just under 1/48 octave (480
    /// points). Fine enough that 1/12-octave smoothing still averages several points,
    /// coarse enough to fit quickly.
    static let pointsPerOctave = 48.0
    static let standardGrid: [Double] = {
        let octaves = log2(20000.0 / 20.0)
        let count = Int((octaves * pointsPerOctave).rounded(.up)) + 1
        let step = octaves / Double(count - 1)
        return (0..<count).map { 20.0 * pow(2.0, Double($0) * step) }
    }()

    /// A curve on `standardGrid` with every value from `value(hz)`.
    static func onStandardGrid(_ value: (Double) -> Double) -> FrequencyCurve {
        FrequencyCurve(frequencies: standardGrid, dB: standardGrid.map(value))
    }

    /// Interpolates linearly in log-frequency, holding the end values outside the curve.
    func value(at hz: Double) -> Double {
        guard let first = frequencies.first, let last = frequencies.last else { return 0 }
        if hz <= first { return dB[0] }
        if hz >= last { return dB[dB.count - 1] }
        // Binary search for the bracketing pair.
        var lo = 0, hi = frequencies.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= hz { lo = mid } else { hi = mid }
        }
        let t = log(hz / frequencies[lo]) / log(frequencies[hi] / frequencies[lo])
        return dB[lo] + t * (dB[hi] - dB[lo])
    }

    /// This curve resampled onto `frequencies` (see `value(at:)`).
    func resampled(to frequencies: [Double]) -> FrequencyCurve {
        FrequencyCurve(frequencies: frequencies, dB: frequencies.map(value(at:)))
    }

    /// Point-by-point sum with `other`, resampling it onto this curve's frequencies if needed.
    func adding(_ other: FrequencyCurve, scale: Double = 1) -> FrequencyCurve {
        let values = other.frequencies == frequencies ? other.dB : frequencies.map(other.value(at:))
        return FrequencyCurve(frequencies: frequencies, dB: zip(dB, values).map { $0 + scale * $1 })
    }

    func offset(by delta: Double) -> FrequencyCurve {
        FrequencyCurve(frequencies: frequencies, dB: dB.map { $0 + delta })
    }

    /// Mean dB over `lower...upper`, or nil if no point falls inside.
    func meanDB(from lower: Double, to upper: Double) -> Double? {
        var sum = 0.0, n = 0
        for (f, v) in zip(frequencies, dB) where f >= lower && f <= upper {
            sum += v; n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }
}
