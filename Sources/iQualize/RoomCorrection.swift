import Foundation
import Observation
import os.log

private let correctionLog = OSLog(subsystem: "com.iqualize", category: "correction")

/// The correction each speaker gets. Identical when both were measured together.
struct CorrectionBands: Equatable, Sendable {
    var left: [EQBand]
    var right: [EQBand]

    static let none = CorrectionBands(left: [], right: [])

    init(left: [EQBand], right: [EQBand]) {
        self.left = left
        self.right = right
    }

    /// The same bands for both speakers.
    init(shared: [EQBand]) {
        self.init(left: shared, right: shared)
    }

    /// Whether the two speakers need different bands, so the correction can't run in the
    /// shared AVAudioUnitEQ.
    var isSplit: Bool { left != right }
    var isEmpty: Bool { left.isEmpty && right.isEmpty }
}

/// A room correction measured for one output device: Bell bands that run under whatever
/// preset is active, for as long as that device is the output. It's a separate layer from
/// presets so switching from Flat to Bass Boost keeps the room corrected, and plugging in
/// headphones (a different device) drops it.
struct RoomCorrection: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    /// Stable CoreAudio UID of the output device this was measured on.
    var deviceUID: String
    /// Display name of that device at measurement time.
    var deviceName: String
    var createdAt: Date
    /// The correction for both speakers, or for the left one when they were measured
    /// separately (see `rightBands`).
    var bands: [EQBand]
    /// The right speaker's correction when left and right were measured separately; nil when
    /// both share `bands`. Mirrors `EQPresetData.rightBands`.
    var rightBands: [EQBand]?
    /// Off keeps the measurement but stops applying it.
    var isEnabled: Bool
    /// Name of the input device the measurement was recorded with, if known.
    var micName: String?
    /// How many mic positions were averaged into the measurement.
    var positionCount: Int
    /// The level-aligned room response the bands were fitted to, and what they aimed for —
    /// kept so the correction can be shown again without re-measuring.
    var measuredResponse: FrequencyCurve?
    /// The right speaker's measured response, when measured separately.
    var rightMeasuredResponse: FrequencyCurve?
    var target: CorrectionTarget?
    var fitSettings: CorrectionFitSettings?

    init(id: UUID = UUID(), name: String, deviceUID: String, deviceName: String,
         createdAt: Date = Date(), bands: [EQBand], rightBands: [EQBand]? = nil, isEnabled: Bool = true,
         micName: String? = nil, positionCount: Int = 1, measuredResponse: FrequencyCurve? = nil,
         rightMeasuredResponse: FrequencyCurve? = nil,
         target: CorrectionTarget? = nil, fitSettings: CorrectionFitSettings? = nil) {
        self.id = id
        self.name = name
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.bands = bands
        self.rightBands = rightBands
        self.isEnabled = isEnabled
        self.micName = micName
        self.positionCount = positionCount
        self.measuredResponse = measuredResponse
        self.rightMeasuredResponse = rightMeasuredResponse
        self.target = target
        self.fitSettings = fitSettings
    }

    enum CodingKeys: String, CodingKey {
        case id, name, deviceUID, deviceName, createdAt, bands, rightBands, isEnabled, micName, positionCount
        case measuredResponse, rightMeasuredResponse, target, fitSettings
    }

    /// Tolerant of fields added later: only the identity, device, and bands are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        deviceUID = try c.decode(String.self, forKey: .deviceUID)
        bands = try c.decode([EQBand].self, forKey: .bands)
        rightBands = try? c.decode([EQBand].self, forKey: .rightBands)
        deviceName = (try? c.decode(String.self, forKey: .deviceName)) ?? deviceUID
        name = (try? c.decode(String.self, forKey: .name)) ?? "Room Correction"
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        micName = try? c.decode(String.self, forKey: .micName)
        positionCount = (try? c.decode(Int.self, forKey: .positionCount)) ?? 1
        measuredResponse = try? c.decode(FrequencyCurve.self, forKey: .measuredResponse)
        rightMeasuredResponse = try? c.decode(FrequencyCurve.self, forKey: .rightMeasuredResponse)
        target = try? c.decode(CorrectionTarget.self, forKey: .target)
        fitSettings = try? c.decode(CorrectionFitSettings.self, forKey: .fitSettings)
    }

    var isSplit: Bool { rightBands != nil }

    /// Total bands across both speakers' corrections (each counted once when shared).
    var bandCount: Int { bands.count + (rightBands?.count ?? 0) }

    /// The bands the engine should run, or nil when nothing should be applied.
    var activeBands: CorrectionBands? {
        let both = CorrectionBands(left: bands, right: rightBands ?? bands)
        guard isEnabled, !both.isEmpty else { return nil }
        return both
    }
}

/// One room correction per output device, persisted as a single JSON blob keyed by device UID.
@available(macOS 14.2, *)
@Observable
@MainActor
final class RoomCorrectionStore {
    private(set) var correctionsByDeviceUID: [String: RoomCorrection] = [:]
    /// Same meaning as `PresetStore.loadFailures`.
    private(set) var loadFailures: [String] = []

    private static let key = "com.iqualize.roomCorrectionsByDevice"
    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        if let stored = PersistedBlob.load([String: RoomCorrection].self, key: Self.key,
                                           describedAs: "Room corrections", from: defaults,
                                           log: correctionLog, failures: &loadFailures) {
            correctionsByDeviceUID = stored
        }
    }

    func correction(forDeviceUID uid: String) -> RoomCorrection? {
        correctionsByDeviceUID[uid]
    }

    /// The bands to run for `uid`: nil when the device has no correction or it's turned off.
    func activeBands(forDeviceUID uid: String) -> CorrectionBands? {
        correctionsByDeviceUID[uid]?.activeBands
    }

    /// Stores `correction` for its device, replacing any earlier one.
    func save(_ correction: RoomCorrection) {
        correctionsByDeviceUID[correction.deviceUID] = correction
        persist()
    }

    func setEnabled(_ enabled: Bool, forDeviceUID uid: String) {
        guard var correction = correctionsByDeviceUID[uid], correction.isEnabled != enabled else { return }
        correction.isEnabled = enabled
        correctionsByDeviceUID[uid] = correction
        persist()
    }

    func remove(forDeviceUID uid: String) {
        guard correctionsByDeviceUID.removeValue(forKey: uid) != nil else { return }
        persist()
    }

    private func persist() {
        PersistedBlob.save(correctionsByDeviceUID, key: Self.key, to: defaults)
    }
}
