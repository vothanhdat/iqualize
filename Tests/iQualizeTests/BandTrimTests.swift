import XCTest
@testable import iQualize

/// "Remove Unused Bands": which bands count as unused, and what's left after trimming.
final class BandTrimTests: XCTestCase {

    private func band(_ hz: Float, _ db: Float, _ type: FilterType = .parametric) -> EQBand {
        EQBand(frequency: hz, gain: db, filterType: type)
    }

    func testOnlyBellAndShelvesUseGain() {
        XCTAssertEqual(FilterType.allCases.filter(\.usesGain), [.parametric, .lowShelf, .highShelf])
    }

    func testGainBandAtZeroDecibelsIsUnused() {
        XCTAssertTrue(band(1000, 0).isUnused)
        XCTAssertTrue(band(100, 0, .lowShelf).isUnused)
        XCTAssertTrue(band(8000, 0, .highShelf).isUnused)
    }

    func testGainThatDisplaysAsZeroCountsAsZero() {
        // The readouts show one decimal, so anything that reads ±0.0 dB is unused.
        XCTAssertTrue(band(1000, 0.04).isUnused)
        XCTAssertTrue(band(1000, -0.04).isUnused)
        XCTAssertFalse(band(1000, 0.1).isUnused)
        XCTAssertFalse(band(1000, -6).isUnused)
    }

    func testPassAndNotchFiltersAreNeverUnused() {
        // They ignore gain and still filter at 0 dB.
        for type in [FilterType.lowPass, .highPass, .bandPass, .notch] {
            XCTAssertFalse(band(1000, 0, type).isUnused, "\(type) at 0 dB still changes the sound")
        }
    }

    func testMutedBandIsJudgedByItsGainNotItsMute() {
        var muted = band(1000, -6)
        muted.muted = true
        XCTAssertFalse(muted.isUnused, "muting is temporary; the band's -6 dB still matters")
    }

    func testRemovesUnusedBandsAndKeepsOrder() {
        let bands = [band(8000, 3), band(20, 0), band(500, -2), band(20000, 0), band(80, 0, .highPass)]
        let kept = bands.removingUnusedBands()
        XCTAssertEqual(kept.map(\.id), [bands[0].id, bands[2].id, bands[4].id])
    }

    func testNothingToRemoveReturnsSameBands() {
        let bands = [band(100, 2), band(1000, -3)]
        XCTAssertEqual(bands.removingUnusedBands().map(\.id), bands.map(\.id))
    }

    func testAllUnusedKeepsLowestFrequencyBandForTheMinimum() {
        let bands = [band(1000, 0), band(20, 0), band(20000, 0)]
        let kept = bands.removingUnusedBands()
        XCTAssertEqual(kept.count, EQPresetData.minBandCount)
        XCTAssertEqual(kept.first?.id, bands[1].id)
    }

    func testEmptyStaysEmpty() {
        XCTAssertTrue([EQBand]().removingUnusedBands().isEmpty)
    }

    // MARK: - +Add buttons

    func testAddedBandStartsAtZeroDecibelsWithNeighborsShape() {
        let neighbor = EQBand(frequency: 8000, gain: -6, bandwidth: 0.5, filterType: .highShelf)
        let added = EQBand.added(at: 12_000, beside: neighbor)
        XCTAssertEqual(added.frequency, 12_000)
        XCTAssertEqual(added.gain, 0, "a new band must not change the sound")
        XCTAssertEqual(added.bandwidth, 0.5)
        XCTAssertEqual(added.filterType, .highShelf)
        XCTAssertNotEqual(added.id, neighbor.id)
    }

    func testAddedBesidePassOrNotchFilterIsABell() {
        for type in [FilterType.lowPass, .highPass, .bandPass, .notch] {
            let added = EQBand.added(at: 30, beside: band(20, 0, type))
            XCTAssertEqual(added.filterType, .parametric, "a copied \(type) would filter even at 0 dB")
            XCTAssertTrue(added.isUnused)
        }
    }
}
