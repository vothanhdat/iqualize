import AVFAudio
import XCTest
@testable import iQualize

/// The room correction runs as a layer ahead of the preset's bands. These cover the band
/// composition and the AVAudioUnitEQ slot bookkeeping that composition depends on.
@available(macOS 14.2, *)
@MainActor
final class CorrectionLayerTests: XCTestCase {
    private let correction = [
        EQBand(frequency: 42, gain: -8, bandwidth: 0.3),
        EQBand(frequency: 110, gain: -4, bandwidth: 0.5),
    ]
    private let preset = [
        EQBand(frequency: 80, gain: 5),
        EQBand(frequency: 4000, gain: -2, bandwidth: 1.5, filterType: .highShelf),
    ]

    func testCorrectionRunsAheadOfThePreset() {
        XCTAssertEqual(AudioEngine.effectiveBands(correction: correction, preset: preset), correction + preset)
        XCTAssertEqual(AudioEngine.effectiveBands(correction: [], preset: preset), preset)
    }

    // MARK: - Linked-mode routing

    func testSharedCorrectionRunsInTheAUAheadOfThePreset() {
        let routing = AudioEngine.linkedRouting(preset: preset, correction: CorrectionBands(shared: correction),
                                                nativeCapacity: 31)
        XCTAssertEqual(routing.native, correction + preset)
        XCTAssertTrue(routing.left.isEmpty)
        XCTAssertTrue(routing.right.isEmpty)
    }

    /// The AU filters both channels alike, so per-speaker corrections go to each channel's
    /// biquad chain and the preset keeps the AU.
    func testSplitCorrectionRunsInEachChannelsChain() {
        let right = [EQBand(frequency: 63, gain: -6, bandwidth: 0.4)]
        let routing = AudioEngine.linkedRouting(preset: preset,
                                                correction: CorrectionBands(left: correction, right: right),
                                                nativeCapacity: 31)
        XCTAssertEqual(routing.native, preset)
        XCTAssertEqual(routing.left, correction)
        XCTAssertEqual(routing.right, right)
    }

    func testOverflowReachesBothChainsAfterASplitCorrection() {
        let right = [EQBand(frequency: 63, gain: -6, bandwidth: 0.4)]
        let routing = AudioEngine.linkedRouting(preset: preset,
                                                correction: CorrectionBands(left: correction, right: right),
                                                nativeCapacity: 1)
        XCTAssertEqual(routing.native, [preset[0]])
        XCTAssertEqual(routing.left, correction + [preset[1]])
        XCTAssertEqual(routing.right, right + [preset[1]])
    }

    func testSharedCorrectionOverflowsLikeAnyBand() {
        let routing = AudioEngine.linkedRouting(preset: preset, correction: CorrectionBands(shared: correction),
                                                nativeCapacity: 3)
        XCTAssertEqual(routing.native, correction + [preset[0]])
        XCTAssertEqual(routing.left, [preset[1]])
        XCTAssertEqual(routing.right, [preset[1]])
    }

    func testNoCorrectionLeavesThePresetAlone() {
        let routing = AudioEngine.linkedRouting(preset: preset, correction: .none, nativeCapacity: 31)
        XCTAssertEqual(routing, AudioEngine.LinkedRouting(native: preset, left: [], right: []))
    }

    func testFlatnessCountsTheCorrection() {
        let flatPreset = EQPresetData.flat.bands
        XCTAssertTrue(AudioEngine.isFlat(AudioEngine.effectiveBands(correction: [], preset: flatPreset)))
        XCTAssertFalse(AudioEngine.isFlat(AudioEngine.effectiveBands(correction: correction, preset: flatPreset)))
    }

    func testFlatnessIgnoresMutedBands() {
        var muted = correction
        for i in muted.indices { muted[i].muted = true }
        XCTAssertTrue(AudioEngine.isFlat(muted))
    }

    func testFreshSlotsAreFullyConfiguredAndTheRestBypassed() {
        let eq = AVAudioUnitEQ(numberOfBands: 8)
        let applied = AudioEngine.configureNativeSlots(eq, bands: preset, previous: nil)

        XCTAssertEqual(applied, preset)
        assertSlots(eq, match: preset)
        for i in preset.count..<eq.bands.count {
            XCTAssertTrue(eq.bands[i].bypass, "slot \(i) should be bypassed")
        }
    }

    /// Turning the correction on shifts the preset's bands to later slots. Every slot has to
    /// end up holding the composed list, not a mix of old and new parameters.
    func testPrependingCorrectionRewritesShiftedSlots() {
        let eq = AVAudioUnitEQ(numberOfBands: 8)
        let before = AudioEngine.configureNativeSlots(eq, bands: preset, previous: nil)

        let composed = AudioEngine.effectiveBands(correction: correction, preset: preset)
        let after = AudioEngine.configureNativeSlots(eq, bands: composed, previous: before)

        XCTAssertEqual(after, composed)
        assertSlots(eq, match: composed)
        for i in composed.count..<eq.bands.count {
            XCTAssertTrue(eq.bands[i].bypass)
        }

        // And turning it back off restores the preset alone, bypassing the freed slots.
        let restored = AudioEngine.configureNativeSlots(eq, bands: preset, previous: after)
        XCTAssertEqual(restored, preset)
        assertSlots(eq, match: preset)
        for i in preset.count..<eq.bands.count {
            XCTAssertTrue(eq.bands[i].bypass)
        }
    }

    func testMutedBandIsWrittenAtZeroGain() {
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let before = AudioEngine.configureNativeSlots(eq, bands: preset, previous: nil)
        var muted = preset
        muted[0].muted = true
        AudioEngine.configureNativeSlots(eq, bands: muted, previous: before)
        XCTAssertEqual(eq.bands[0].gain, 0)
    }

    /// AUNBandEQ drops bandwidth writes while a slot is a shelf, so a Shelf → Bell change
    /// that keeps the same bandwidth must still write it, or the Bell gets the AU's default.
    func testTypeChangeRewritesParametersTheOldTypeIgnored() {
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let shelf = [EQBand(frequency: 4000, gain: -2, bandwidth: 1.5, filterType: .highShelf)]
        let before = AudioEngine.configureNativeSlots(eq, bands: shelf, previous: nil)

        let bell = [EQBand(frequency: 4000, gain: -2, bandwidth: 1.5, filterType: .parametric)]
        AudioEngine.configureNativeSlots(eq, bands: bell, previous: before)
        assertSlots(eq, match: bell)

        // Same for gain, which a low-pass ignores.
        let lowPass = [EQBand(frequency: 4000, gain: 6, bandwidth: 1.5, filterType: .lowPass)]
        let passApplied = AudioEngine.configureNativeSlots(eq, bands: lowPass, previous: bell)
        let bellAgain = [EQBand(frequency: 4000, gain: 6, bandwidth: 1.5, filterType: .parametric)]
        AudioEngine.configureNativeSlots(eq, bands: bellAgain, previous: passApplied)
        assertSlots(eq, match: bellAgain)
    }

    func testBandsBeyondTheAUCapacityAreLeftForTheBiquadOverflow() {
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let applied = AudioEngine.configureNativeSlots(eq, bands: correction + preset, previous: nil)
        XCTAssertEqual(applied, correction)
    }

    /// Compares every parameter the slot's filter type uses. AUNBandEQ reports 0 for the
    /// ones it ignores (bandwidth on shelves and low/high-pass, gain on pass and notch).
    private func assertSlots(_ eq: AVAudioUnitEQ, match bands: [EQBand],
                             file: StaticString = #filePath, line: UInt = #line) {
        for (i, band) in bands.enumerated() {
            let slot = eq.bands[i]
            XCTAssertFalse(slot.bypass, "slot \(i) bypassed", file: file, line: line)
            XCTAssertEqual(slot.filterType, band.filterType.avType, "slot \(i) type", file: file, line: line)
            XCTAssertEqual(slot.frequency, band.frequency, accuracy: 0.01, "slot \(i) frequency", file: file, line: line)
            if band.filterType.usesGain {
                XCTAssertEqual(slot.gain, AudioEngine.effectiveGain(band), accuracy: 0.01,
                               "slot \(i) gain", file: file, line: line)
            }
            if [.parametric, .bandPass, .notch].contains(band.filterType) {
                XCTAssertEqual(slot.bandwidth, band.bandwidth, accuracy: 0.01,
                               "slot \(i) bandwidth", file: file, line: line)
            }
        }
    }
}
