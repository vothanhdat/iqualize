import XCTest
@testable import iQualize

final class CorrectionFitterTests: XCTestCase {
    private typealias Support = RoomMeasurementTestSupport
    private let sampleRate = 48000.0
    /// A bass-heavy room: a mode at 45 Hz, a broad dip at 120 Hz, a bump at 300 Hz.
    private let room = [
        EQBand(frequency: 45, gain: 8, bandwidth: 0.5),
        EQBand(frequency: 120, gain: -6, bandwidth: 0.7),
        EQBand(frequency: 300, gain: 5, bandwidth: 0.6),
    ]

    private func curve(of bands: [EQBand], level: Double = 0) -> FrequencyCurve {
        FrequencyCurve.onStandardGrid {
            BiquadResponse.magnitudeDB(for: bands, frequency: $0, sampleRate: self.sampleRate) + level
        }
    }

    // MARK: - Fitting

    func testFitsASyntheticRoomWithinOneDB() {
        var settings = CorrectionFitSettings()
        settings.maxBoostDB = 6
        let result = CorrectionFitter.fit(measured: curve(of: room, level: -12), target: .flat,
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertLessThan(result.residualRMSDB, 1)
        XCTAssertEqual(result.levelOffsetDB, -12, accuracy: 0.5)
    }

    func testRespectsEveryLimit() {
        let settings = CorrectionFitSettings(lowerHz: 30, upperHz: 400, maxBoostDB: 2, maxCutDB: 6, maxBands: 2)
        let result = CorrectionFitter.fit(measured: curve(of: room), target: .flat,
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertLessThanOrEqual(result.bands.count, 2)
        for band in result.bands {
            XCTAssertEqual(band.filterType, .parametric)
            XCTAssertLessThanOrEqual(band.gain, 2.05)
            XCTAssertGreaterThanOrEqual(band.gain, -6.05)
            XCTAssertGreaterThanOrEqual(band.frequency, 30)
            XCTAssertLessThanOrEqual(band.frequency, 400)
        }
    }

    func testBandsComeOutSortedByFrequency() {
        let result = CorrectionFitter.fit(measured: curve(of: room), target: .flat,
                                          settings: CorrectionFitSettings(), sampleRate: sampleRate)
        XCTAssertEqual(result.bands.map(\.frequency), result.bands.map(\.frequency).sorted())
    }

    func testAFlatRoomNeedsNoBands() {
        let result = CorrectionFitter.fit(measured: FrequencyCurve.onStandardGrid { _ in -20 }, target: .flat,
                                          settings: CorrectionFitSettings(), sampleRate: sampleRate)
        XCTAssertTrue(result.bands.isEmpty)
        XCTAssertLessThan(result.residualRMSDB, 1e-9)
    }

    func testIsDeterministic() {
        let a = CorrectionFitter.fit(measured: curve(of: room), target: .flat,
                                     settings: CorrectionFitSettings(), sampleRate: sampleRate)
        let b = CorrectionFitter.fit(measured: curve(of: room), target: .flat,
                                     settings: CorrectionFitSettings(), sampleRate: sampleRate)
        XCTAssertEqual(a, b)
    }

    /// A deep, narrow null is a cancellation: boosting it spends headroom without filling it.
    func testLeavesANarrowNullAlone() {
        let null = [EQBand(frequency: 90, gain: -15, bandwidth: 0.12)]
        let measured = ImpulseResponseAnalysis.smoothed(curve(of: null), fraction: 1.0 / 6)
        let result = CorrectionFitter.fit(measured: measured, target: .flat,
                                          settings: CorrectionFitSettings(), sampleRate: sampleRate)
        XCTAssertTrue(result.bands.allSatisfy { $0.gain <= 0 }, "boosted a null: \(result.bands)")
    }

    func testFullRangeCorrection() {
        let settings = CorrectionFitSettings(lowerHz: 20, upperHz: 20000, maxBoostDB: 6, maxCutDB: 12, maxBands: 12)
        let fullRoom = room + [EQBand(frequency: 3000, gain: 4), EQBand(frequency: 9000, gain: -5, bandwidth: 1.2)]
        let result = CorrectionFitter.fit(measured: curve(of: fullRoom), target: .flat,
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertLessThan(result.residualRMSDB, 1)
    }

    func testPredictionIsTheAlignedMeasurementPlusTheCorrection() {
        let result = CorrectionFitter.fit(measured: curve(of: room), target: .flat,
                                          settings: CorrectionFitSettings(), sampleRate: sampleRate)
        for f in [40.0, 120, 300] {
            XCTAssertEqual(result.predicted.value(at: f),
                           result.aligned.value(at: f) + result.correction.value(at: f), accuracy: 1e-9)
        }
    }

    // MARK: - Q and gain limits

    private func q(_ band: EQBand) -> Double { octavesToQ(Double(band.bandwidth)) }

    /// A narrow, strong room mode needs a high-Q cut. Raising Max Q lets the fit use one;
    /// lowering it keeps every band at or below the limit.
    func testMaxQBoundsHowNarrowBandsGet() throws {
        let mode = [EQBand(frequency: 45, gain: 12, bandwidth: Float(EQBand.qToOctaves(22)))]
        let measured = curve(of: mode)
        var settings = CorrectionFitSettings()
        settings.maxQ = 30
        let narrow = CorrectionFitter.fit(measured: measured, target: .flat, settings: settings, sampleRate: sampleRate)
        XCTAssertTrue(narrow.bands.allSatisfy { q($0) <= 30.5 })
        XCTAssertGreaterThan(try XCTUnwrap(narrow.bands.map(q).max()), 14, "the mode needs more than the old Q 14")

        settings.maxQ = 5
        let wide = CorrectionFitter.fit(measured: measured, target: .flat, settings: settings, sampleRate: sampleRate)
        XCTAssertFalse(wide.bands.isEmpty)
        XCTAssertTrue(wide.bands.allSatisfy { q($0) <= 5.1 }, "\(wide.bands.map(q))")
    }

    func testBoostCanReachTwelveDecibels() {
        let broadDip = [EQBand(frequency: 120, gain: -11, bandwidth: 1.5)]
        var settings = CorrectionFitSettings()
        settings.maxBoostDB = 12
        let result = CorrectionFitter.fit(measured: curve(of: broadDip), target: .flat,
                                          settings: settings, sampleRate: sampleRate)
        let biggest = result.bands.map(\.gain).max() ?? 0
        XCTAssertGreaterThan(biggest, 6)
        XCTAssertLessThanOrEqual(biggest, 12.05)
    }

    /// A single band stops at −24 dB, so a cut deeper than that takes two bands.
    func testCutsDeeperThanOneBandStayWithinEachBandsRange() {
        let hugeMode = [EQBand(frequency: 60, gain: 24, bandwidth: 0.5), EQBand(frequency: 60, gain: 4, bandwidth: 0.5)]
        var settings = CorrectionFitSettings()
        settings.maxCutDB = 30
        let result = CorrectionFitter.fit(measured: curve(of: hugeMode), target: .flat,
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertTrue(result.bands.allSatisfy { $0.gain >= EQBand.gainRange.lowerBound })
        XCTAssertLessThan(result.correction.value(at: 60), -24.5)
    }

    func testSettingsSavedBeforeMaxQDecodeWithDefaults() throws {
        let json = #"{"lowerHz": 20, "upperHz": 400, "maxBoostDB": 2, "maxCutDB": 10, "maxBands": 8}"#
        let settings = try JSONDecoder().decode(CorrectionFitSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.upperHz, 400)
        XCTAssertEqual(settings.maxBands, 8)
        XCTAssertEqual(settings.maxQ, CorrectionFitSettings().maxQ)
        XCTAssertNil(settings.protectionHighPassHz)
    }

    // MARK: - Target

    func testTargetShape() {
        XCTAssertEqual(CorrectionTarget.flat.dB(at: 50), 0)
        let target = CorrectionTarget(bassLiftDB: 4, trebleTiltDBPerOctave: -0.5)
        XCTAssertEqual(target.dB(at: CorrectionTarget.bassShelfHz), 2, accuracy: 1e-9)
        XCTAssertEqual(target.dB(at: 20), 4, accuracy: 0.2)
        // Two octaves above the pivot: −1 dB of tilt, plus what's left of the shelf.
        XCTAssertEqual(target.dB(at: 4000), -1, accuracy: 0.01)
    }

    func testFitAimsAtTheTarget() {
        let target = CorrectionTarget(bassLiftDB: 4, trebleTiltDBPerOctave: 0)
        var settings = CorrectionFitSettings()
        settings.maxBoostDB = 6
        let result = CorrectionFitter.fit(measured: FrequencyCurve.onStandardGrid { _ in 0 }, target: target,
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertEqual(result.predicted.value(at: 40), target.dB(at: 40), accuracy: 1)
    }

    // MARK: - End to end

    /// Sweep → room → mic noise → latency → a 44.1 kHz mic → analysis → smoothing → fit.
    /// Applying the fitted bands to the room must leave it flat within 1.5 dB RMS.
    func testMeasuringAndCorrectingASyntheticRoom() {
        let parameters = SweepParameters.standard(sampleRate: sampleRate)
        var recorded = Support.filter(
            Support.recording(of: SweepSignal.sweep(parameters), sampleRate: sampleRate, delay: 0.037),
            bands: room, sampleRate: sampleRate)
        var rng = SplitMix64(seed: 42)
        for i in recorded.indices {
            recorded[i] = recorded[i] * 0.3 + Float(rng.nextUnitDouble() * 2 - 1) * 0.0005
        }
        let micRecording = ImpulseResponseAnalysis.resample(recorded, from: sampleRate, to: 44100)

        let measured = ImpulseResponseAnalysis.smoothed(
            ImpulseResponseAnalysis.magnitudeResponse(recording: micRecording, recordingRate: 44100,
                                                      sweep: parameters),
            fraction: 1.0 / 6)
        var settings = CorrectionFitSettings()
        settings.maxBoostDB = 6
        let result = CorrectionFitter.fit(measured: measured, target: .flat, settings: settings,
                                          sampleRate: sampleRate)

        var sumSquares = 0.0, count = 0
        for f in FrequencyCurve.standardGrid where f >= 30 && f <= 500 {
            let corrected = BiquadResponse.magnitudeDB(for: room + result.bands, frequency: f, sampleRate: sampleRate)
            sumSquares += corrected * corrected
            count += 1
        }
        XCTAssertLessThan(sqrt(sumSquares / Double(count)), 1.5)
    }
}
