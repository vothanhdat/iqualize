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

    static let smoothingChoices: [(label: String, fraction: Double)] = [
        ("1/3 octave", 1.0 / 3), ("1/6 octave", 1.0 / 6), ("1/12 octave", 1.0 / 12),
    ]

    let session: RoomMeasurementSession
    private let audioEngine: AudioEngine
    private let presetStore: PresetStore
    private let correctionStore: RoomCorrectionStore

    var step: Step = .setup
    var target = CorrectionTarget()
    var settings = CorrectionFitSettings()
    var smoothing: Double = 1.0 / 6
    /// Confirmation of the last apply/save, shown in the footer.
    private(set) var statusMessage: String?

    @ObservationIgnored private var cachedFitKey: FitKey?
    @ObservationIgnored private var cachedFit: CorrectionFitter.Result?

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

    /// Each position smoothed the same way as the average, for the Measure graph.
    var positionResponses: [FrequencyCurve] {
        session.positions.map { position in
            let calibrated = session.calibration?.applied(to: position.response) ?? position.response
            return ImpulseResponseAnalysis.smoothed(calibrated, fraction: smoothing)
        }
    }

    /// The fit for the current measurements and controls. Cached, since the view reads it
    /// several times per render; it reruns only when an input actually changes.
    var fit: CorrectionFitter.Result? {
        let key = FitKey(positionIDs: session.positions.map(\.id), calibration: session.calibration,
                         smoothing: smoothing, target: target, settings: settings,
                         sampleRate: session.sweepSampleRate)
        if key == cachedFitKey { return cachedFit }
        let result = session.roomResponse(smoothing: smoothing).map {
            CorrectionFitter.fit(measured: $0, target: target, settings: settings,
                                 sampleRate: session.sweepSampleRate)
        }
        cachedFitKey = key
        cachedFit = result
        return result
    }

    private struct FitKey: Equatable {
        var positionIDs: [UUID]
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
        guard let fit, !fit.bands.isEmpty, let uid = session.outputDeviceUID else { return }
        let correction = RoomCorrection(
            name: "Room Correction", deviceUID: uid, deviceName: session.outputDeviceName,
            bands: fit.bands, micName: session.selectedInput?.name,
            positionCount: session.positions.count, measuredResponse: fit.aligned,
            target: target, fitSettings: settings)
        correctionStore.save(correction)
        audioEngine.refreshCorrection()
        statusMessage = "Room correction is on for \(session.outputDeviceName). It runs under every preset; "
            + "turn it off from the EQ window's footer or the menu bar."
    }

    /// Saves the fitted bands as an ordinary, editable preset instead.
    func saveAsPreset() {
        guard let fit, !fit.bands.isEmpty else { return }
        let name = presetStore.dedupedName(base: "Room Correction (\(session.outputDeviceName))")
        let preset = EQPresetData(id: UUID(), name: name, bands: fit.bands, isBuiltIn: false)
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
