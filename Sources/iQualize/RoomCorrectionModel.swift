import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// State behind the Room Correction window: the wizard step, the fit controls, and the
/// live fit of whatever has been measured so far.
@available(macOS 14.2, *)
@MainActor
@Observable
final class RoomCorrectionModel {
    enum Step: Int, CaseIterable, Identifiable {
        case setup, measure, correct
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .setup: "1 · Set Up"
            case .measure: "2 · Measure"
            case .correct: "3 · Correct"
            }
        }
    }

    /// The fitted correction: one shared by both speakers, or one per speaker.
    struct RoomFit: Equatable {
        /// The shared fit when measured together; the left speaker's when measured separately.
        var left: CorrectionFitter.Result
        /// The right speaker's fit; nil when both share `left`.
        var right: CorrectionFitter.Result?

        var isSplit: Bool { right != nil }
        var hasBands: Bool { !left.bands.isEmpty || !(right?.bands.isEmpty ?? true) }
        var bands: CorrectionBands {
            CorrectionBands(left: left.bands, right: right?.bands ?? left.bands)
        }

        func result(for channel: SpeakerChannel) -> CorrectionFitter.Result {
            channel == .right ? (right ?? left) : left
        }

        /// How much louder the right speaker plays than the left at the listening position,
        /// in dB, when they were measured separately.
        var rightLouderByDB: Double? {
            right.map { $0.levelOffsetDB - left.levelOffsetDB }
        }
    }

    static let smoothingChoices: [(label: String, fraction: Double)] = [
        ("1/3 octave", 1.0 / 3), ("1/6 octave", 1.0 / 6), ("1/12 octave", 1.0 / 12),
    ]

    let session: RoomMeasurementSession
    private let audioEngine: AudioEngine
    private let presetStore: PresetStore
    private let correctionStore: RoomCorrectionStore

    var step: Step = .setup
    /// Bass lift and treble tilt; the bass limit is applied on top (see `effectiveTarget`).
    var target = CorrectionTarget()
    var settings = CorrectionFitSettings()
    var smoothing: Double = 1.0 / 6
    /// Keep the correction away from bass the speakers can't play.
    var limitBass = true
    /// A bass limit the user set by hand; nil follows the one detected from the measurement.
    var bassLimitOverrideHz: Double?
    /// Add a high-pass just below the bass limit, so small woofers aren't driven by bass
    /// they can't reproduce.
    var protectSpeakers = true
    /// Which speaker the Correct graph shows when they were measured separately.
    var graphChannel: SpeakerChannel = .left
    /// Confirmation of the last apply/save, shown in the footer.
    private(set) var statusMessage: String?

    @ObservationIgnored private var cachedFitKey: FitKey?
    @ObservationIgnored private var cachedFit: RoomFit?

    init(audioEngine: AudioEngine, presetStore: PresetStore, correctionStore: RoomCorrectionStore) {
        self.audioEngine = audioEngine
        self.presetStore = presetStore
        self.correctionStore = correctionStore
        self.session = RoomMeasurementSession(audioEngine: audioEngine)
    }

    // MARK: - Derived state

    /// The correction already saved for the current output, if any.
    var existingCorrection: RoomCorrection? {
        session.outputDeviceUID.flatMap { correctionStore.correction(forDeviceUID: $0) }
    }

    func canOpen(_ step: Step) -> Bool {
        switch step {
        case .setup: true
        case .measure: session.selectedInput != nil
        case .correct: !session.positions.isEmpty
        }
    }

    /// Where the speakers' bass rolls off, judged from both speakers' averaged response.
    var detectedBassLimitHz: Double? {
        session.roomResponse(.both, smoothing: 1.0 / 6).flatMap(CorrectionTarget.estimatedBassRolloffHz)
    }

    /// The bass limit in effect: the user's, else the detected one; nil when off or when the
    /// speakers reach 20 Hz.
    var effectiveBassLimitHz: Double? {
        guard limitBass else { return nil }
        return bassLimitOverrideHz ?? detectedBassLimitHz
    }

    var effectiveTarget: CorrectionTarget {
        var target = target
        target.bassRolloffHz = effectiveBassLimitHz
        return target
    }

    var effectiveSettings: CorrectionFitSettings {
        var settings = settings
        settings.protectionHighPassHz = protectSpeakers
            ? effectiveBassLimitHz.map { $0 * CorrectionFitSettings.protectionHighPassRatio }
            : nil
        return settings
    }

    /// Each position's response for `channel`, smoothed and calibrated like the average, for
    /// the Measure graph.
    func positionResponses(_ channel: SpeakerChannel) -> [FrequencyCurve] {
        session.positions.compactMap { $0.responses[channel] }.map { response in
            let calibrated = session.calibration?.applied(to: response) ?? response
            return ImpulseResponseAnalysis.smoothed(calibrated, fraction: smoothing)
        }
    }

    /// The fit for the current measurements and controls. Cached, since the view reads it
    /// several times per render; it reruns only when an input actually changes.
    var fit: RoomFit? {
        let target = effectiveTarget
        let settings = effectiveSettings
        let key = FitKey(positionIDs: session.positions.map(\.id), mode: session.mode,
                         calibration: session.calibration, smoothing: smoothing, target: target,
                         settings: settings, sampleRate: session.sweepSampleRate)
        if key == cachedFitKey { return cachedFit }

        let rate = session.sweepSampleRate
        let fits = session.fitChannels.compactMap { channel in
            session.roomResponse(channel, smoothing: smoothing).map {
                CorrectionFitter.fit(measured: $0, target: target, settings: settings, sampleRate: rate)
            }
        }
        let result: RoomFit? = switch fits.count {
        case 1: RoomFit(left: fits[0], right: nil)
        case 2: RoomFit(left: fits[0], right: fits[1])
        default: nil
        }
        cachedFitKey = key
        cachedFit = result
        return result
    }

    private struct FitKey: Equatable {
        var positionIDs: [UUID]
        var mode: RoomMeasurementSession.MeasurementMode
        var calibration: MicCalibration?
        var smoothing: Double
        var target: CorrectionTarget
        var settings: CorrectionFitSettings
        var sampleRate: Double
    }

    // MARK: - Actions

    func loadCalibration() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Microphone Calibration File"
        panel.message = "Calibration files come with measurement microphones such as the miniDSP UMIK-1."
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "cal") ?? .data,
                                     UTType(filenameExtension: "frd") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            session.calibration = try MicCalibration.parse(text, name: url.deletingPathExtension().lastPathComponent)
            statusMessage = nil
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't read “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func clearCalibration() {
        session.calibration = nil
    }

    /// Saves the fitted bands as this output's room correction and turns it on.
    func applyToDevice() {
        guard let fit, fit.hasBands, let uid = session.outputDeviceUID else { return }
        let correction = RoomCorrection(
            name: "Room Correction", deviceUID: uid, deviceName: session.outputDeviceName,
            bands: fit.left.bands, rightBands: fit.right?.bands, micName: session.selectedInput?.name,
            positionCount: session.positions.count, measuredResponse: fit.left.aligned,
            rightMeasuredResponse: fit.right?.aligned, target: effectiveTarget, fitSettings: effectiveSettings)
        correctionStore.save(correction)
        audioEngine.refreshCorrection()
        statusMessage = "Room correction is on for \(session.outputDeviceName). It runs under every preset; "
            + "turn it off from the EQ window's footer or the menu bar."
    }

    /// Saves the fitted bands as an ordinary, editable preset instead — a split L/R preset
    /// when the speakers were measured separately.
    func saveAsPreset() {
        guard let fit, fit.hasBands else { return }
        // A preset needs at least one band per channel; a speaker that needed no
        // correction gets a single flat Bell.
        func atLeastOne(_ bands: [EQBand]) -> [EQBand] {
            bands.isEmpty ? [EQBand(frequency: 1000, gain: 0)] : bands
        }
        let name = presetStore.dedupedName(base: "Room Correction (\(session.outputDeviceName))")
        let preset = EQPresetData(id: UUID(), name: name, bands: atLeastOne(fit.left.bands),
                                  rightBands: fit.right.map { atLeastOne($0.bands) }, isBuiltIn: false)
        presetStore.saveCustomPreset(preset)
        statusMessage = "Saved as the preset “\(name)”. Pick it from the preset list to edit or use it."
    }

    func setExistingCorrectionEnabled(_ enabled: Bool) {
        guard let uid = session.outputDeviceUID else { return }
        correctionStore.setEnabled(enabled, forDeviceUID: uid)
        audioEngine.refreshCorrection()
    }

    func removeExistingCorrection() {
        guard let uid = session.outputDeviceUID else { return }
        correctionStore.remove(forDeviceUID: uid)
        audioEngine.refreshCorrection()
        statusMessage = "Removed the room correction for \(session.outputDeviceName)."
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func clearStatus() {
        statusMessage = nil
    }
}
