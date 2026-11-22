import XCTest
@testable import iQualize

/// The compact, unitless labels the band readout grid falls back to when a cell
/// is too narrow for the full "-12.5 dB" / "1.25 kHz" / "Q 0.71" form.
final class ReadoutFormatTests: XCTestCase {

    func testGainCompactKeepsSignAndOneDecimal() {
        XCTAssertEqual(formatDBCompact(0), "+0.0")
        XCTAssertEqual(formatDBCompact(5), "+5.0")
        XCTAssertEqual(formatDBCompact(-12.5), "-12.5")
        XCTAssertEqual(formatDB(-12.5), "-12.5 dB", "full form is unchanged")
    }

    func testFrequencyCompactBelowOneKilohertzIsWholeHertz() {
        XCTAssertEqual(formatHzCompact(20), "20")
        XCTAssertEqual(formatHzCompact(459.6), "460")
        XCTAssertEqual(formatHzCompact(999), "999")
    }

    func testFrequencyCompactAboveOneKilohertzUsesTrimmedKSuffix() {
        XCTAssertEqual(formatHzCompact(1000), "1k")
        XCTAssertEqual(formatHzCompact(1250), "1.25k")
        XCTAssertEqual(formatHzCompact(2000), "2k")
        XCTAssertEqual(formatHzCompact(5600), "5.6k")
        XCTAssertEqual(formatHzCompact(10_000), "10k")
        XCTAssertEqual(formatHzCompact(14_500), "14.5k")
        XCTAssertEqual(formatHzCompact(20_000), "20k")
    }

    func testBandwidthCompactFollowsDisplayMode() {
        // One octave ≈ Q 1.41.
        XCTAssertEqual(formatBandwidthCompact(octaves: 1, display: .q), "1.4")
        // Two octaves ≈ Q 0.67 — below 1, so two decimals.
        XCTAssertEqual(formatBandwidthCompact(octaves: 2, display: .q), "0.67")
        XCTAssertEqual(formatBandwidthCompact(octaves: 0.33, display: .oct), "0.33")
    }

    func testCompactLabelsFitFiveMonospacedCharacters() {
        // The grid's fallback is sized around this: five 11 pt monospaced characters
        // fit a cell at 20 bands in the default window width.
        let samples = [
            formatDBCompact(-24), formatDBCompact(24),
            formatHzCompact(14_567), formatHzCompact(1_234), formatHzCompact(999),
            formatBandwidthCompact(octaves: 0.05, display: .q),
            formatBandwidthCompact(octaves: 10, display: .q),
            formatBandwidthCompact(octaves: 10, display: .oct),
        ]
        for s in samples {
            XCTAssertLessThanOrEqual(s.count, 5, "\(s) is longer than five characters")
        }
    }
}
