import XCTest
@testable import iQualize

/// The measurement path from a recorded sweep to a magnitude response. A synthetic
/// "room" (biquads of known response) stands in for speakers and a microphone.
final class ImpulseResponseAnalysisTests: XCTestCase {
    private typealias Support = RoomMeasurementTestSupport
    private let sampleRate = 48000.0
    private lazy var parameters = SweepParameters.standard(sampleRate: sampleRate)
    private lazy var sweep = SweepSignal.sweep(parameters)

    // MARK: - Signals

    func testSweepHasRequestedLengthAndLevel() {
        XCTAssertEqual(sweep.count, 288_000)
        XCTAssertEqual(ImpulseResponseAnalysis.peakLevelDBFS(sweep), 20 * log10(0.25), accuracy: 0.05)
    }

    func testSweepAmplitudeIsCappedAtMinusSixDBFS() {
        var loud = parameters
        loud.amplitude = 1
        XCTAssertLessThanOrEqual(ImpulseResponseAnalysis.peakLevelDBFS(SweepSignal.sweep(loud)), -6.02 + 0.01)
    }

    func testPinkNoiseIsDeterministicAtTheRequestedLevel() {
        let a = SweepSignal.pinkNoise(duration: 3, sampleRate: sampleRate, amplitudeDBFS: -30, seed: 7)
        let b = SweepSignal.pinkNoise(duration: 3, sampleRate: sampleRate, amplitudeDBFS: -30, seed: 7)
        XCTAssertEqual(a, b)
        XCTAssertEqual(ImpulseResponseAnalysis.rmsLevelDBFS(a), -30, accuracy: 0.5)
    }

    func testRealFFTRoundTripsAndIsScaledToTheTrueDFT() throws {
        let fft = try XCTUnwrap(RealFFT(log2n: 10))
        let x = (0..<1024).map { Float(sin(Double($0) * 0.1) + 0.3 * cos(Double($0) * 0.37)) }
        let spectrum = fft.forward(x)
        let back = fft.inverse(re: spectrum.re, im: spectrum.im)
        XCTAssertLessThan(zip(x, back).map { abs($0 - $1) }.max()!, 1e-4)

        let cosine = (0..<1024).map { Float(cos(2 * Double.pi * 8 * Double($0) / 1024)) }
        XCTAssertEqual(fft.forward(cosine).re[8], 512, accuracy: 0.1)
    }

    // MARK: - Deconvolution

    func testBareSweepMeasuresFlat() {
        let curve = ImpulseResponseAnalysis.magnitudeResponse(
            recording: Support.recording(of: sweep, sampleRate: sampleRate, delay: 0),
            recordingRate: sampleRate, sweep: parameters)
        XCTAssertLessThan(Support.maxDeviation(curve, from: 30, to: 16000), 0.5)
        XCTAssertLessThan(Support.maxDeviation(curve, from: 20, to: 20000), 1.0)
    }

    func testLatencyDoesNotChangeTheMagnitude() {
        let curve = ImpulseResponseAnalysis.magnitudeResponse(
            recording: Support.recording(of: sweep, sampleRate: sampleRate, delay: 0.037),
            recordingRate: sampleRate, sweep: parameters)
        XCTAssertLessThan(Support.maxDeviation(curve, from: 30, to: 16000), 0.5)
    }

    func testRecoversAKnownBell() {
        let bell = EQBand(frequency: 100, gain: 6, bandwidth: 1)
        let recorded = Support.filter(Support.recording(of: sweep, sampleRate: sampleRate, delay: 0.01),
                                      bands: [bell], sampleRate: sampleRate)
        let curve = ImpulseResponseAnalysis.magnitudeResponse(recording: recorded, recordingRate: sampleRate,
                                                              sweep: parameters)
        XCTAssertEqual(curve.value(at: 100), 6, accuracy: 0.5)
        let deviation = Support.maxDeviation(curve, from: 30, to: 16000) {
            BiquadResponse.magnitudeDB(for: bell, frequency: $0, sampleRate: self.sampleRate)
        }
        XCTAssertLessThan(deviation, 0.5)
    }

    /// A mic at 44.1 kHz recording a sweep played at 48 kHz.
    func testRecordingAtAnotherSampleRateIsResampled() {
        let bell = EQBand(frequency: 100, gain: 6, bandwidth: 1)
        let recorded = Support.filter(Support.recording(of: sweep, sampleRate: sampleRate, delay: 0.01),
                                      bands: [bell], sampleRate: sampleRate)
        let at44k = ImpulseResponseAnalysis.resample(recorded, from: sampleRate, to: 44100)
        XCTAssertEqual(Double(at44k.count), Double(recorded.count) * 44100 / sampleRate, accuracy: 64)

        let curve = ImpulseResponseAnalysis.magnitudeResponse(recording: at44k, recordingRate: 44100,
                                                              sweep: parameters)
        let deviation = Support.maxDeviation(curve, from: 30, to: 16000) {
            BiquadResponse.magnitudeDB(for: bell, frequency: $0, sampleRate: self.sampleRate)
        }
        XCTAssertLessThan(deviation, 0.75)
    }

    // MARK: - Smoothing and averaging

    func testSmoothingKeepsAFlatCurveFlat() {
        let flat = FrequencyCurve.onStandardGrid { _ in -3 }
        let smoothed = ImpulseResponseAnalysis.smoothed(flat, fraction: 1.0 / 6)
        XCTAssertLessThan(Support.maxDeviation(smoothed, from: 20, to: 20000) { _ in -3 }, 1e-9)
    }

    func testSmoothingFillsInANarrowNotch() {
        let notch = [EQBand(frequency: 90, gain: -15, bandwidth: 0.12)]
        let raw = FrequencyCurve.onStandardGrid {
            BiquadResponse.magnitudeDB(for: notch, frequency: $0, sampleRate: self.sampleRate)
        }
        let smoothed = ImpulseResponseAnalysis.smoothed(raw, fraction: 1.0 / 6)
        XCTAssertGreaterThan(smoothed.value(at: 90), raw.value(at: 90) + 3)
    }

    func testPowerAverageAveragesPowerNotDecibels() throws {
        let average = try XCTUnwrap(ImpulseResponseAnalysis.powerAverage([
            FrequencyCurve.onStandardGrid { _ in 0 },
            FrequencyCurve.onStandardGrid { _ in -100 },
        ]))
        XCTAssertEqual(average.value(at: 1000), 10 * log10(0.5), accuracy: 1e-6)
    }

    func testStandardGridSpansTheAudibleBand() {
        let grid = FrequencyCurve.standardGrid
        XCTAssertEqual(grid.first!, 20, accuracy: 1e-9)
        XCTAssertEqual(grid.last!, 20000, accuracy: 1e-6)
        XCTAssertEqual(grid.count, 480)
    }
}
