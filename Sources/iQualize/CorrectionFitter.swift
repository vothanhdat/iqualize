import Foundation

/// Limits on the correction the fitter may build.
struct CorrectionFitSettings: Codable, Equatable, Sendable {
    /// Correct between these frequencies only. Above ~500 Hz a room's response changes
    /// within inches, so correcting it only helps the exact mic position.
    var lowerHz: Double = 20
    var upperHz: Double = 500
    /// Boosts are capped low: a dip is usually a cancellation, and boosting it spends
    /// amplifier headroom without filling it.
    var maxBoostDB: Double = 3
    var maxCutDB: Double = 12
    var maxBands: Int = 10

    static let upperHzRange: ClosedRange<Double> = 200...20000
    static let maxBoostRange: ClosedRange<Double> = 0...6
    static let maxCutRange: ClosedRange<Double> = 3...24
    static let maxBandsRange: ClosedRange<Int> = 1...20
}

extension BiquadResponse {
    /// Exact magnitude of one band's biquad at `frequency`, in dB.
    static func magnitudeDB(for band: EQBand, frequency: Double, sampleRate: Double) -> Double {
        let c = coefficients(for: band, sampleRate: sampleRate)
        let w = 2 * Double.pi * frequency / sampleRate
        return magnitudeDB(c, cosW: cos(w), cos2W: cos(2 * w))
    }

    /// Exact magnitude of a cascade of bands at `frequency`, in dB.
    static func magnitudeDB(for bands: [EQBand], frequency: Double, sampleRate: Double) -> Double {
        bands.reduce(0) { $0 + magnitudeDB(for: $1, frequency: frequency, sampleRate: sampleRate) }
    }

    /// |H(e^jω)|² = (b0² + b1² + b2² + 2(b0b1 + b1b2)cos ω + 2b0b2 cos 2ω) / (same in a).
    static func magnitudeDB(_ c: BiquadCoefficients, cosW: Double, cos2W: Double) -> Double {
        let num = c.b0 * c.b0 + c.b1 * c.b1 + c.b2 * c.b2
            + 2 * (c.b0 * c.b1 + c.b1 * c.b2) * cosW + 2 * c.b0 * c.b2 * cos2W
        let den = c.a0 * c.a0 + c.a1 * c.a1 + c.a2 * c.a2
            + 2 * (c.a0 * c.a1 + c.a1 * c.a2) * cosW + 2 * c.a0 * c.a2 * cos2W
        guard num > 0, den > 0 else { return -120 }
        return 10 * log10(num / den)
    }
}

/// Fits Bell bands that bring a measured room response toward a target.
///
/// 1. Align levels: shift the measurement so its mean matches the target over a reference
///    band (just above the correction range when correcting bass only, so the corrected
///    bass meets the uncorrected mids at the same level).
/// 2. Decide what correction is wanted at each frequency: cut every peak (up to
///    `maxCutDB`), but boost only broad dips, by at most `maxBoostDB`.
/// 3. Greedy: put a Bell on the largest remaining deviation, sized from its half-height
///    width, skipping dips narrower than ⅓ octave (cancellations a boost can't fill).
/// 4. Refine every band's frequency, gain, and bandwidth by coordinate descent on the RMS
///    error inside the range, plus a penalty for correction spilling outside it.
///
/// Fully deterministic, and fast enough to rerun live as the user drags a control.
enum CorrectionFitter {
    struct Result: Equatable, Sendable {
        /// Sorted by frequency.
        var bands: [EQBand]
        /// The bands' combined response, on the measurement's frequencies.
        var correction: FrequencyCurve
        /// The measurement after level alignment — what the graph compares to the target.
        var aligned: FrequencyCurve
        /// `aligned + correction`: what the room should measure with the correction on.
        var predicted: FrequencyCurve
        /// How far the measurement was shifted to meet the target.
        var levelOffsetDB: Double
        /// RMS of `predicted − target` inside the correction range.
        var residualRMSDB: Double
    }

    /// Stop placing bands once nothing in range is off by more than this.
    static let toleranceDB = 1.0
    /// Dips narrower than this (at half depth) are left alone.
    static let narrowestBoostOctaves = 1.0 / 3.0
    static let bandwidthRange: ClosedRange<Double> = 0.1...3
    /// Weight of correction outside the range relative to error inside it.
    static let spillWeight = 0.5

    static func fit(measured: FrequencyCurve, target: CorrectionTarget,
                    settings: CorrectionFitSettings, sampleRate: Double) -> Result {
        let freqs = measured.frequencies
        let targetCurve = target.curve(on: freqs)
        let lower = max(20, min(settings.lowerHz, settings.upperHz))
        let upper = min(20000, max(settings.lowerHz, settings.upperHz))

        // 1. Level alignment.
        let reference: ClosedRange<Double> = upper <= 1000
            ? upper...min(20000, upper * 4)
            : max(lower, 200)...upper
        let deviation = FrequencyCurve(frequencies: freqs, dB: zip(measured.dB, targetCurve.dB).map { $0 - $1 })
        let levelOffset = deviation.meanDB(from: reference.lowerBound, to: reference.upperBound)
            ?? deviation.meanDB(from: lower, to: upper)
            ?? 0
        let aligned = measured.offset(by: -levelOffset)
        let error = deviation.offset(by: -levelOffset)

        var problem = Problem(error: error, lower: lower, upper: upper,
                              settings: settings, sampleRate: sampleRate)
        // Round to values that read cleanly in the band readouts, and drop bands the
        // refinement left doing nothing.
        let bands = problem.solve()
            .map(rounded)
            .filter { abs($0.gain) >= 0.3 }
            .sorted { $0.frequency < $1.frequency }

        let correction = FrequencyCurve(frequencies: freqs, dB: freqs.map {
            BiquadResponse.magnitudeDB(for: bands, frequency: $0, sampleRate: sampleRate)
        })
        let predicted = aligned.adding(correction)
        var sumSq = 0.0, n = 0
        for i in freqs.indices where freqs[i] >= lower && freqs[i] <= upper {
            let r = predicted.dB[i] - targetCurve.dB[i]
            sumSq += r * r; n += 1
        }
        return Result(bands: bands, correction: correction, aligned: aligned, predicted: predicted,
                      levelOffsetDB: levelOffset, residualRMSDB: n > 0 ? sqrt(sumSq / Double(n)) : 0)
    }

    /// Frequency to 0.1 Hz, gain to 0.1 dB, bandwidth to 0.01 octave.
    private static func rounded(_ b: EQBand) -> EQBand {
        let frequency = (Double(b.frequency) * 10).rounded() / 10
        let gain = (Double(b.gain) * 10).rounded() / 10
        let bandwidth = (Double(b.bandwidth) * 100).rounded() / 100
        return EQBand(frequency: Float(frequency), gain: Float(gain), bandwidth: Float(bandwidth),
                      filterType: .parametric)
    }

    // MARK: - Optimisation

    /// One band in optimisation coordinates: log2 frequency, gain dB, log2 bandwidth.
    private struct Params: Equatable {
        var logF: Double
        var gain: Double
        var logBW: Double

        subscript(i: Int) -> Double {
            get { i == 0 ? logF : i == 1 ? gain : logBW }
            set { if i == 0 { logF = newValue } else if i == 1 { gain = newValue } else { logBW = newValue } }
        }

        var band: EQBand {
            EQBand(frequency: Float(pow(2, logF)), gain: Float(gain),
                   bandwidth: Float(pow(2, logBW)), filterType: .parametric)
        }
    }

    private struct Problem {
        let freqs: [Double]
        /// Measured − target after level alignment, at each fit point.
        let error: [Double]
        let cosW: [Double]
        let cos2W: [Double]
        let inRange: [Bool]
        /// Correction wanted at each point (0 outside the range).
        var desired: [Double]
        var weights: [Double]
        let bounds: [ClosedRange<Double>]
        let settings: CorrectionFitSettings
        let sampleRate: Double

        init(error: FrequencyCurve, lower: Double, upper: Double,
             settings: CorrectionFitSettings, sampleRate: Double) {
            // Fit on the range plus 1.5 octaves either side, where spill is penalised.
            let margin = pow(2, 1.5)
            let lo = max(20, lower / margin), hi = min(20000, upper * margin)
            let idx = error.frequencies.indices.filter { error.frequencies[$0] >= lo && error.frequencies[$0] <= hi }
            freqs = idx.map { error.frequencies[$0] }
            let err = idx.map { error.dB[$0] }
            self.error = err
            cosW = freqs.map { cos(2 * Double.pi * $0 / sampleRate) }
            cos2W = freqs.map { cos(4 * Double.pi * $0 / sampleRate) }
            inRange = freqs.map { $0 >= lower && $0 <= upper }

            // Dips are judged on a ⅓-octave average, so a narrow cancellation asks for
            // little or no boost while a broad sag still gets one.
            let wide = Self.movingAverage(err, freqs: freqs, octaves: CorrectionFitter.narrowestBoostOctaves)
            var desired = [Double](repeating: 0, count: freqs.count)
            for i in freqs.indices where inRange[i] {
                desired[i] = err[i] > 0
                    ? max(-err[i], -settings.maxCutDB)
                    : min(max(-wide[i], 0), settings.maxBoostDB)
            }
            self.desired = desired
            weights = inRange.map { $0 ? 1 : CorrectionFitter.spillWeight }
            bounds = [
                log2(lower)...log2(upper),
                -settings.maxCutDB...settings.maxBoostDB,
                log2(CorrectionFitter.bandwidthRange.lowerBound)...log2(CorrectionFitter.bandwidthRange.upperBound),
            ]
            self.settings = settings
            self.sampleRate = sampleRate
        }

        static func movingAverage(_ values: [Double], freqs: [Double], octaves: Double) -> [Double] {
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

        /// Grid span around `index` where the measured error stays below half its depth there.
        func halfDepthSpan(around index: Int) -> (Int, Int) {
            let half = error[index] / 2
            guard half < 0 else { return (index, index) }
            var left = index, right = index
            while left > 0 && error[left - 1] <= half { left -= 1 }
            while right < error.count - 1 && error[right + 1] <= half { right += 1 }
            return (left, right)
        }

        /// The deepest point of the dip containing `index`. Boost requests are capped, so
        /// the greedy pick can land on a shoulder; the dip's width is judged from its bottom.
        func bottomOfDip(around index: Int) -> Int {
            var left = index, right = index
            while left > 0 && error[left - 1] < 0 { left -= 1 }
            while right < error.count - 1 && error[right + 1] < 0 { right += 1 }
            return (left...right).min { error[$0] < error[$1] } ?? index
        }

        /// The whole dip around `index` (out to where the error turns positive), widened by
        /// the ⅓-octave averaging radius that spread its boost request onto neighbours.
        func negativeSpan(around index: Int) -> (Int, Int) {
            var left = index, right = index
            while left > 0 && error[left - 1] < 0 { left -= 1 }
            while right < error.count - 1 && error[right + 1] < 0 { right += 1 }
            let radius = Int((CorrectionFitter.narrowestBoostOctaves / 2 * FrequencyCurve.pointsPerOctave).rounded())
            return (max(0, left - radius), min(error.count - 1, right + radius))
        }

        func response(_ p: Params) -> [Double] {
            let c = BiquadResponse.coefficients(for: p.band, sampleRate: sampleRate)
            return freqs.indices.map { BiquadResponse.magnitudeDB(c, cosW: cosW[$0], cos2W: cos2W[$0]) }
        }

        func cost(_ total: [Double]) -> Double {
            var j = 0.0
            for i in total.indices {
                let r = total[i] - desired[i]
                j += weights[i] * r * r
            }
            return j
        }

        mutating func solve() -> [EQBand] {
            guard settings.maxBands > 0, !freqs.isEmpty else { return [] }
            var params: [Params] = []
            var responses: [[Double]] = []
            var total = [Double](repeating: 0, count: freqs.count)
            var excluded = [Bool](repeating: false, count: freqs.count)

            var attempts = 0
            while params.count < settings.maxBands && attempts < settings.maxBands * 4 {
                attempts += 1
                // Largest remaining deviation in range.
                var best = -1
                var bestAbs = 0.0
                for i in freqs.indices where inRange[i] && !excluded[i] {
                    let r = desired[i] - total[i]
                    if abs(r) > bestAbs { bestAbs = abs(r); best = i }
                }
                guard best >= 0, bestAbs >= CorrectionFitter.toleranceDB else { break }

                let g = desired[best] - total[best]

                // A boost is judged on the measured dip's own width at half depth: the
                // desired curve is already ⅓-octave averaged there, so it always looks
                // broad. A narrow dip is a cancellation; stop asking for any boost across
                // it, so its shoulders don't attract boosts either.
                if g > 0 {
                    let (dipLeft, dipRight) = halfDepthSpan(around: bottomOfDip(around: best))
                    if log2(freqs[dipRight] / freqs[dipLeft]) < CorrectionFitter.narrowestBoostOctaves {
                        let (zeroLeft, zeroRight) = negativeSpan(around: best)
                        for i in zeroLeft...zeroRight where desired[i] > 0 {
                            desired[i] = 0
                            excluded[i] = true
                        }
                        excluded[best] = true
                        continue
                    }
                }

                // Half-height span of the remaining deviation, for the new band's width.
                var left = best, right = best
                while left > 0 && inRange[left - 1]
                        && (desired[left - 1] - total[left - 1]) * g > 0
                        && abs(desired[left - 1] - total[left - 1]) >= abs(g) / 2 { left -= 1 }
                while right < freqs.count - 1 && inRange[right + 1]
                        && (desired[right + 1] - total[right + 1]) * g > 0
                        && abs(desired[right + 1] - total[right + 1]) >= abs(g) / 2 { right += 1 }
                let widthOctaves = max(1 / FrequencyCurve.pointsPerOctave, log2(freqs[right] / freqs[left]))

                let p = Params(
                    logF: log2(freqs[best]),
                    gain: min(max(g, bounds[1].lowerBound), bounds[1].upperBound),
                    logBW: log2(min(max(widthOctaves, CorrectionFitter.bandwidthRange.lowerBound),
                                    CorrectionFitter.bandwidthRange.upperBound))
                )
                let r = response(p)
                params.append(p)
                responses.append(r)
                for i in total.indices { total[i] += r[i] }
                refine(&params, &responses, &total, sweeps: 12)
            }
            refine(&params, &responses, &total, sweeps: 60)
            return params.map(\.band)
        }

        /// Coordinate descent: nudge one parameter of one band at a time, keep any move
        /// that lowers the cost, and halve a parameter's step when neither direction helps.
        func refine(_ params: inout [Params], _ responses: inout [[Double]], _ total: inout [Double],
                    sweeps: Int) {
            guard !params.isEmpty else { return }
            let initialSteps = [1.0 / 12, 0.5, 0.15]
            let minimumSteps = [1.0 / 192, 0.02, 0.01]
            var steps = Array(repeating: initialSteps, count: params.count)
            var current = cost(total)

            for _ in 0..<sweeps {
                var moved = false
                for b in params.indices {
                    for k in 0..<3 where steps[b][k] >= minimumSteps[k] {
                        var accepted = false
                        for direction in [1.0, -1.0] {
                            var candidate = params[b]
                            candidate[k] = min(max(candidate[k] + direction * steps[b][k], bounds[k].lowerBound),
                                               bounds[k].upperBound)
                            guard candidate != params[b] else { continue }
                            let r = response(candidate)
                            var trial = total
                            for i in trial.indices { trial[i] += r[i] - responses[b][i] }
                            let c = cost(trial)
                            if c < current - 1e-9 {
                                params[b] = candidate
                                responses[b] = r
                                total = trial
                                current = c
                                accepted = true
                                moved = true
                                break
                            }
                        }
                        if !accepted { steps[b][k] *= 0.5 }
                    }
                }
                if !moved && steps.allSatisfy({ zip($0, minimumSteps).allSatisfy { $0 < $1 } }) { break }
            }
        }
    }
}
