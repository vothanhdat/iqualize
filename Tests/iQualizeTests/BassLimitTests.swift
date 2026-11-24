import XCTest
@testable import iQualize

/// Small speakers can't play the deepest bass. The correction must find where they roll off,
/// aim for that roll-off rather than flat, and never boost below it.
final class BassLimitTests: XCTestCase {
    private let sampleRate = 48000.0

    /// A sealed speaker −6 dB at `rolloffHz` (12 dB/octave below), in a room with modes.
    private func smallSpeaker(rolloffHz: Double, modes: [EQBand] = []) -> FrequencyCurve {
        FrequencyCurve.onStandardGrid { f in
            let corner = rolloffHz * pow(3, 0.25)
            return -10 * log10(1 + pow(corner / f, 4))
                + BiquadResponse.magnitudeDB(for: modes, frequency: f, sampleRate: self.sampleRate)
        }
    }

    private let roomModes = [
        EQBand(frequency: 85, gain: 6, bandwidth: 0.4),
        EQBand(frequency: 160, gain: -4, bandwidth: 0.5),
    ]

    // MARK: - Detection

    func testDetectsASmallSpeakersRolloff() throws {
        let measured = ImpulseResponseAnalysis.smoothed(smallSpeaker(rolloffHz: 45, modes: roomModes),
                                                        fraction: 1.0 / 6)
        let detected = try XCTUnwrap(CorrectionTarget.estimatedBassRolloffHz(of: measured))
        XCTAssertEqual(detected, 45, accuracy: 8)
    }

    func testDetectsAHigherRolloff() throws {
        let detected = try XCTUnwrap(CorrectionTarget.estimatedBassRolloffHz(of: smallSpeaker(rolloffHz: 80)))
        XCTAssertEqual(detected, 80, accuracy: 10)
    }

    func testFullRangeSpeakersHaveNoLimit() {
        XCTAssertNil(CorrectionTarget.estimatedBassRolloffHz(of: FrequencyCurve.onStandardGrid { _ in -10 }))
    }

    /// A broad room dip that comes back up below it is the room, not the speaker.
    func testARecoveringRoomDipIsNotMistakenForTheLimit() {
        let dip = [EQBand(frequency: 70, gain: -9, bandwidth: 0.7)]
        let measured = FrequencyCurve.onStandardGrid {
            BiquadResponse.magnitudeDB(for: dip, frequency: $0, sampleRate: self.sampleRate)
        }
        XCTAssertNil(CorrectionTarget.estimatedBassRolloffHz(of: measured))
    }

    func testManualLimitSnapsToFiveHertzSteps() {
        XCTAssertEqual(CorrectionTarget.snappedBassRolloffHz(52.4), 50)
        XCTAssertEqual(CorrectionTarget.snappedBassRolloffHz(57.6), 60)
        XCTAssertEqual(CorrectionTarget.snappedBassRolloffHz(97.5), 100)
        XCTAssertEqual(CorrectionTarget.snappedBassRolloffHz(22), 25)
        XCTAssertEqual(CorrectionTarget.snappedBassRolloffHz(5), 25)
        XCTAssertEqual(CorrectionTarget.snappedBassRolloffHz(260), 200)
    }

    func testLimitCanGoDownTo25Hz() {
        XCTAssertEqual(CorrectionTarget(bassRolloffHz: 25).effectiveBassRolloffHz, 25)
        XCTAssertEqual(CorrectionTarget(bassRolloffHz: 10).effectiveBassRolloffHz, 25)
        XCTAssertLessThan(25, CorrectionTarget.lowBassWarningHz)
    }

    // MARK: - Target

    func testTargetRollsOffBelowTheLimit() {
        let target = CorrectionTarget(bassRolloffHz: 50)
        XCTAssertEqual(target.dB(at: 50), -6, accuracy: 0.1)
        XCTAssertEqual(target.dB(at: 25), target.dB(at: 50) - 12, accuracy: 1.5)
        XCTAssertEqual(target.dB(at: 500), 0, accuracy: 0.05)
    }

    // MARK: - Fitting

    func testNoBandSitsBelowTheLimitAndNothingBoostsThere() {
        let measured = smallSpeaker(rolloffHz: 45, modes: roomModes)
        var settings = CorrectionFitSettings()
        settings.maxBoostDB = 6
        let result = CorrectionFitter.fit(measured: measured, target: CorrectionTarget(bassRolloffHz: 45),
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertFalse(result.bands.isEmpty, "the 85 Hz mode should still be cut")
        XCTAssertTrue(result.bands.allSatisfy { $0.frequency >= 45 }, "\(result.bands)")
        for f in FrequencyCurve.standardGrid where f < 45 {
            XCTAssertLessThan(result.correction.value(at: f), 1.0, "boosting \(f) Hz")
        }
        XCTAssertLessThan(result.residualRMSDB, 1.5)
    }

    /// Without the limit the same speaker gets its missing bass "fixed" with boosts — the
    /// behaviour the limit exists to prevent.
    func testWithoutTheLimitTheFitTriesToBoostTheMissingBass() {
        var settings = CorrectionFitSettings()
        settings.maxBoostDB = 6
        let result = CorrectionFitter.fit(measured: smallSpeaker(rolloffHz: 45), target: .flat,
                                          settings: settings, sampleRate: sampleRate)
        XCTAssertGreaterThan(result.correction.value(at: 35), 2)
    }

    func testProtectionHighPassIsAddedAndCutsBelowTheLimit() throws {
        var settings = CorrectionFitSettings()
        settings.protectionHighPassHz = 45 * CorrectionFitSettings.protectionHighPassRatio
        let result = CorrectionFitter.fit(measured: smallSpeaker(rolloffHz: 45, modes: roomModes),
                                          target: CorrectionTarget(bassRolloffHz: 45),
                                          settings: settings, sampleRate: sampleRate)
        let highPass = try XCTUnwrap(result.bands.first { $0.filterType == .highPass })
        XCTAssertEqual(Double(highPass.frequency), 31.5, accuracy: 0.1)
        XCTAssertLessThan(result.correction.value(at: 20), -6)
        // Barely touches what the speakers do play.
        XCTAssertGreaterThan(result.correction.value(at: 100) - BiquadResponse.magnitudeDB(
            for: result.bands.filter { $0.filterType != .highPass }, frequency: 100, sampleRate: sampleRate), -0.3)
    }
}
