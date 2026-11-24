import XCTest
@testable import iQualize

final class MicCalibrationTests: XCTestCase {
    private let umikStyle = """
    "Sens Factor =-1.378dB, SERNO: 7101234"
    * miniDSP calibration
    10\t-3.2\t0
    100 -0.5
    1000, 0.0
    this line is junk
    20000\t2.5\t12
    """

    func testParsesHeaderAndMixedSeparators() throws {
        let cal = try MicCalibration.parse(umikStyle, name: "UMIK-1")
        XCTAssertEqual(cal.name, "UMIK-1")
        XCTAssertEqual(try XCTUnwrap(cal.sensitivityDB), -1.378, accuracy: 1e-9)
        XCTAssertEqual(cal.frequencies, [10, 100, 1000, 20000])
        XCTAssertEqual(cal.deviationsDB, [-3.2, -0.5, 0, 2.5])
    }

    func testInterpolatesInLogFrequencyAndHoldsTheEnds() throws {
        let cal = try MicCalibration.parse(umikStyle, name: "UMIK-1")
        // Halfway between 100 and 1000 Hz on a log axis.
        XCTAssertEqual(cal.dB(at: sqrt(100 * 1000)), -0.25, accuracy: 1e-6)
        XCTAssertEqual(cal.dB(at: 5), -3.2)
        XCTAssertEqual(cal.dB(at: 30000), 2.5)
    }

    func testRowsNeedNotBeSortedAndDuplicatesAreDropped() throws {
        let cal = try MicCalibration.parse("1000 1\n100 2\n100 9\n", name: "x")
        XCTAssertEqual(cal.frequencies, [100, 1000])
        XCTAssertEqual(cal.deviationsDB.count, 2)
    }

    func testApplyingSubtractsTheMicsDeviation() throws {
        let cal = try MicCalibration.parse("20 2\n20000 2\n", name: "x")
        let measured = FrequencyCurve.onStandardGrid { _ in 5 }
        XCTAssertEqual(cal.applied(to: measured).value(at: 1000), 3, accuracy: 1e-9)
    }

    func testFileWithoutDataRowsIsRejected() {
        XCTAssertThrowsError(try MicCalibration.parse("hello\n100 1\n", name: "x"))
        XCTAssertThrowsError(try MicCalibration.parse("", name: "x"))
    }
}
