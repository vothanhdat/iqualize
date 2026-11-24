import XCTest
@testable import iQualize

@available(macOS 14.2, *)
@MainActor
final class RoomCorrectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.iqualize.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private let storeKey = "com.iqualize.roomCorrectionsByDevice"

    private func makeCorrection(device: String = "BuiltInSpeakerDevice",
                                bands: [EQBand] = [EQBand(frequency: 48, gain: -7, bandwidth: 0.4)]) -> RoomCorrection {
        RoomCorrection(name: "Room", deviceUID: device, deviceName: "MacBook Pro Speakers", bands: bands)
    }

    func testSavedCorrectionSurvivesReload() {
        let store = RoomCorrectionStore(userDefaults: defaults)
        let correction = makeCorrection()
        store.save(correction)

        let reloaded = RoomCorrectionStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.correction(forDeviceUID: "BuiltInSpeakerDevice"), correction)
        XCTAssertEqual(reloaded.activeBands(forDeviceUID: "BuiltInSpeakerDevice"), correction.bands)
        XCTAssertTrue(reloaded.loadFailures.isEmpty)
    }

    func testCorrectionsAreKeptPerDevice() {
        let store = RoomCorrectionStore(userDefaults: defaults)
        store.save(makeCorrection(device: "A", bands: [EQBand(frequency: 50, gain: -3)]))
        store.save(makeCorrection(device: "B", bands: [EQBand(frequency: 90, gain: -5)]))

        XCTAssertEqual(store.activeBands(forDeviceUID: "A")?.first?.frequency, 50)
        XCTAssertEqual(store.activeBands(forDeviceUID: "B")?.first?.frequency, 90)
        XCTAssertNil(store.activeBands(forDeviceUID: "Headphones"))
    }

    func testSavingAgainReplacesTheDevicesCorrection() {
        let store = RoomCorrectionStore(userDefaults: defaults)
        store.save(makeCorrection(bands: [EQBand(frequency: 50, gain: -3)]))
        store.save(makeCorrection(bands: [EQBand(frequency: 70, gain: -2)]))
        XCTAssertEqual(store.correctionsByDeviceUID.count, 1)
        XCTAssertEqual(store.activeBands(forDeviceUID: "BuiltInSpeakerDevice")?.first?.frequency, 70)
    }

    func testDisabledCorrectionIsKeptButNotApplied() {
        let store = RoomCorrectionStore(userDefaults: defaults)
        store.save(makeCorrection())
        store.setEnabled(false, forDeviceUID: "BuiltInSpeakerDevice")

        let reloaded = RoomCorrectionStore(userDefaults: defaults)
        XCTAssertNotNil(reloaded.correction(forDeviceUID: "BuiltInSpeakerDevice"))
        XCTAssertNil(reloaded.activeBands(forDeviceUID: "BuiltInSpeakerDevice"))

        reloaded.setEnabled(true, forDeviceUID: "BuiltInSpeakerDevice")
        XCTAssertNotNil(reloaded.activeBands(forDeviceUID: "BuiltInSpeakerDevice"))
    }

    func testRemoveDropsTheCorrection() {
        let store = RoomCorrectionStore(userDefaults: defaults)
        store.save(makeCorrection())
        store.remove(forDeviceUID: "BuiltInSpeakerDevice")
        XCTAssertNil(RoomCorrectionStore(userDefaults: defaults).correction(forDeviceUID: "BuiltInSpeakerDevice"))
    }

    func testEmptyBandsAreNeverApplied() {
        let store = RoomCorrectionStore(userDefaults: defaults)
        store.save(makeCorrection(bands: []))
        XCTAssertNil(store.activeBands(forDeviceUID: "BuiltInSpeakerDevice"))
    }

    func testCorruptBlobIsPreservedAndReported() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: storeKey)

        let store = RoomCorrectionStore(userDefaults: defaults)
        XCTAssertTrue(store.correctionsByDeviceUID.isEmpty)
        XCTAssertEqual(store.loadFailures.count, 1)

        let backups = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(storeKey).corrupt.") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(defaults.data(forKey: backups[0]), garbage)
    }

    func testDecodingToleratesMissingOptionalFields() throws {
        let json = """
        {"BuiltInSpeakerDevice": {"id": "\(UUID().uuidString)", "deviceUID": "BuiltInSpeakerDevice",
          "bands": [{"frequency": 48, "gain": -7, "bandwidth": 0.4}]}}
        """
        defaults.set(Data(json.utf8), forKey: storeKey)

        let store = RoomCorrectionStore(userDefaults: defaults)
        let correction = try XCTUnwrap(store.correction(forDeviceUID: "BuiltInSpeakerDevice"))
        XCTAssertTrue(correction.isEnabled)
        XCTAssertEqual(correction.positionCount, 1)
        XCTAssertEqual(correction.deviceName, "BuiltInSpeakerDevice")
        XCTAssertTrue(store.loadFailures.isEmpty)
    }
}
