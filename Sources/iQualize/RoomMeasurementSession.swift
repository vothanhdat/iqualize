import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation
import Observation
import os.log

private let measurementLog = OSLog(subsystem: "com.iqualize", category: "roomMeasurement")

/// Drives a room measurement: a level check, then one sweep per microphone position.
///
/// The sweep plays through its own short-lived AVAudioEngine on the default output. The
/// capture helper's tap already excludes this process, so the sweep is neither recaptured
/// nor EQ'd, and the raw room is what gets measured. Meanwhile the main engine renders
/// silence (`AudioEngine.measurementMuted`), and since the tap mutes the apps it captures,
/// the room is quiet apart from the sweep.
@available(macOS 14.2, *)
@MainActor
@Observable
final class RoomMeasurementSession {
    enum Activity: Equatable {
        case idle
        case checkingLevel
        case measuring
        case analyzing
    }

    enum LevelVerdict: Equatable {
        case tooQuiet
        case good
        case tooLoud
    }

    struct LevelReport: Equatable {
        var peakDBFS: Float
        var rmsDBFS: Float
        var noiseFloorDBFS: Float
        var verdict: LevelVerdict
    }

    /// One recorded sweep: the unsmoothed, uncalibrated response at one mic position.
    struct Position: Identifiable, Equatable {
        let id = UUID()
        let response: FrequencyCurve
        let peakDBFS: Float
        var clipped: Bool { peakDBFS > -0.5 }
    }

    static let maxPositions = 5
    /// Sweep peak (−12 dBFS). The level check plays pink noise at the sweep's RMS, so what
    /// the user hears while setting the volume is how loud the sweep will be.
    static let sweepAmplitude: Float = 0.25
    static let levelCheckRMSDBFS: Float = -15
    static let sweepDuration = 6.0
    private static let preRollSeconds = 0.4
    private static let tailSeconds = 1.0

    private(set) var activity: Activity = .idle
    private(set) var inputDevices: [AudioInputDevice] = []
    var selectedInputUID: String?
    private(set) var outputDeviceName: String = ""
    private(set) var outputDeviceUID: String?
    private(set) var outputWarning: String?
    private(set) var levelReport: LevelReport?
    /// Live mic peak while capturing, for the meter.
    private(set) var liveLevelDBFS: Float = -120
    private(set) var positions: [Position] = []
    /// Sample rate the sweeps played at — the rate the correction must be fitted for.
    private(set) var sweepSampleRate: Double = 48000
    private(set) var errorMessage: String?
    private(set) var permissionDenied = false
    var calibration: MicCalibration?

    private let audioEngine: AudioEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: SweepPlayer?
    @ObservationIgnored private var recorder: MicRecorder?

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
        refreshDevices()
    }

    var selectedInput: AudioInputDevice? {
        inputDevices.first { $0.uid == selectedInputUID }
    }

    var isBusy: Bool { activity != .idle }

    /// Re-reads the output device and the available microphones, keeping the selected mic
    /// if it's still there.
    func refreshDevices() {
        if let output = try? getDefaultOutputDevice() {
            outputDeviceName = output.name
            if output.uid != outputDeviceUID, !positions.isEmpty {
                // Measurements belong to the speakers they were taken on.
                positions.removeAll()
                levelReport = nil
            }
            outputDeviceUID = output.uid
            outputWarning = roomCorrectionOutputWarning(for: output.id)
        }
        inputDevices = listAudioInputDevices()
        if selectedInput == nil {
            selectedInputUID = (inputDevices.first { !$0.isBluetooth } ?? inputDevices.first)?.uid
        }
    }

    // MARK: - Actions

    func checkLevel() {
        guard !isBusy, let device = selectedInput else { return }
        task = Task { [weak self] in await self?.runLevelCheck(device: device) }
    }

    func measurePosition() {
        guard !isBusy, positions.count < Self.maxPositions, let device = selectedInput else { return }
        task = Task { [weak self] in await self?.runMeasurement(device: device) }
    }

    func removePosition(id: Position.ID) {
        positions.removeAll { $0.id == id }
    }

    func removeAllPositions() {
        positions.removeAll()
    }

    /// Stops whatever is playing or recording right away.
    func cancel() {
        task?.cancel()
        player?.stop()
    }

    /// The averaged, calibrated, smoothed room response — what the fitter corrects — or nil
    /// before the first measurement.
    func roomResponse(smoothing fraction: Double) -> FrequencyCurve? {
        guard var average = ImpulseResponseAnalysis.powerAverage(positions.map(\.response)) else { return nil }
        if let calibration {
            average = calibration.applied(to: average)
        }
        return ImpulseResponseAnalysis.smoothed(average, fraction: fraction)
    }

    // MARK: - Flows

    private func runLevelCheck(device: AudioInputDevice) async {
        guard await ensurePermission() else { return }
        activity = .checkingLevel
        errorMessage = nil
        defer { finish() }
        do {
            let player = SweepPlayer()
            let rate = player.outputSampleRate
            let noiseSeconds = 2.5
            let noise = SweepSignal.pinkNoise(duration: noiseSeconds, sampleRate: rate,
                                              amplitudeDBFS: Self.levelCheckRMSDBFS, seed: 1)
            let capture = try await capture(noise, sampleRate: rate, player: player, device: device)

            let rec = capture.recording
            let floor = ImpulseResponseAnalysis.rmsLevelDBFS(Array(rec.prefix(capture.preRollFrames)))
            // Skip the output's latency at the start and the fades at both ends.
            let start = min(rec.count, capture.preRollFrames + Int(0.25 * capture.micRate))
            let end = min(rec.count, capture.preRollFrames + Int((noiseSeconds - 0.1) * capture.micRate))
            let during = start < end ? Array(rec[start..<end]) : []
            let peak = ImpulseResponseAnalysis.peakLevelDBFS(during)
            let rms = ImpulseResponseAnalysis.rmsLevelDBFS(during)
            levelReport = LevelReport(peakDBFS: peak, rmsDBFS: rms, noiseFloorDBFS: floor,
                                      verdict: Self.verdict(peak: peak, rms: rms, floor: floor))
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clipping is a hard fail. Below that, the sweep needs to clear the room's noise floor
    /// by a comfortable margin (the sweep itself gains ~30 dB more through deconvolution).
    static func verdict(peak: Float, rms: Float, floor: Float) -> LevelVerdict {
        if peak > -1 { return .tooLoud }
        if rms < -55 || rms - floor < 15 { return .tooQuiet }
        return .good
    }

    private func runMeasurement(device: AudioInputDevice) async {
        guard await ensurePermission() else { return }
        activity = .measuring
        errorMessage = nil
        defer { finish() }
        do {
            let player = SweepPlayer()
            let rate = player.outputSampleRate
            let parameters = SweepParameters.standard(sampleRate: rate, duration: Self.sweepDuration,
                                                      amplitude: Self.sweepAmplitude)
            let capture = try await capture(SweepSignal.sweep(parameters), sampleRate: rate,
                                            player: player, device: device)
            let peak = ImpulseResponseAnalysis.peakLevelDBFS(capture.recording)
            guard peak > -60 else {
                errorMessage = "The microphone barely heard the sweep. Check that the right microphone "
                    + "is selected and turn the volume up a little."
                return
            }

            activity = .analyzing
            let recording = capture.recording
            let micRate = capture.micRate
            let response = await Task.detached(priority: .userInitiated) {
                ImpulseResponseAnalysis.magnitudeResponse(recording: recording, recordingRate: micRate,
                                                          sweep: parameters)
            }.value
            try Task.checkCancellation()
            sweepSampleRate = rate
            positions.append(Position(response: response, peakDBFS: peak))
            if peak > -0.5 {
                errorMessage = "That sweep clipped the microphone, so this position is unreliable. "
                    + "Turn the volume down, remove it, and measure again."
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        activity = .idle
        liveLevelDBFS = -120
        task = nil
    }

    private func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            permissionDenied = false
            return true
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            permissionDenied = !granted
            return granted
        default:
            permissionDenied = true
            return false
        }
    }

    private struct Capture {
        var recording: [Float]
        var micRate: Double
        /// Frames recorded before the signal started — the room's background noise.
        var preRollFrames: Int
    }

    /// Records from `device` while playing `signal`, with a short pre-roll for the noise
    /// floor and a tail for the room (and the output's latency) to finish. System audio is
    /// muted throughout and restored however this exits.
    private func capture(_ signal: [Float], sampleRate: Double, player: SweepPlayer,
                         device: AudioInputDevice) async throws -> Capture {
        let micRate = (try? getDeviceNominalSampleRate(device.id)).flatMap { $0 > 0 ? $0 : nil } ?? 48000
        let recorder = MicRecorder(deviceUID: device.uid, sampleRate: micRate)
        self.recorder = recorder
        self.player = player
        audioEngine.measurementMuted = true
        defer {
            player.stop()
            _ = recorder.stop()
            audioEngine.measurementMuted = false
            self.player = nil
            self.recorder = nil
        }

        try recorder.start()
        let meter = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.liveLevelDBFS = recorder.takePeakDBFS()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { meter.cancel() }

        try await Task.sleep(for: .seconds(Self.preRollSeconds))
        let preRoll = recorder.frameCount
        try player.play(signal, sampleRate: sampleRate)
        try await Task.sleep(for: .seconds(Double(signal.count) / sampleRate + Self.tailSeconds))
        let recording = recorder.stop()
        os_log(.default, log: measurementLog, "captured %{public}d frames at %{public}.0f Hz from %{public}@",
               recording.count, micRate, device.name)
        return Capture(recording: recording, micRate: micRate, preRollFrames: min(preRoll, recording.count))
    }
}

// MARK: - Sweep player

/// Plays one stereo buffer through the default output on its own engine, separate from the
/// EQ graph so the measurement hears the raw speakers.
@MainActor
final class SweepPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    /// The default output's hardware rate, read from the engine that will play the signal
    /// so no resampling sits between it and the speakers. It has to be this engine: an I/O
    /// node only stays valid while its engine is alive, and reading the format through a
    /// throwaway `AVAudioEngine()` crashed with a use-after-free.
    var outputSampleRate: Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : 48000
    }

    func play(_ samples: [Float], sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw NSError(domain: "iQualize", code: -300,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare the test signal"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            for channel in 0..<2 {
                buffer.floatChannelData![channel].update(from: src.baseAddress!, count: samples.count)
            }
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        try engine.start()
        node.scheduleBuffer(buffer, completionHandler: nil)
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}

// MARK: - Microphone recorder

/// Records mono float samples from one input device through an AudioQueue, which binds to
/// a device by UID without touching the system default input.
final class MicRecorder: @unchecked Sendable {
    let deviceUID: String
    let sampleRate: Double
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakSinceRead: Float = 0
    private var queue: AudioQueueRef?
    private let callbackQueue = DispatchQueue(label: "com.iqualize.room-measurement.mic")
    private static let bufferFrames = 4096

    init(deviceUID: String, sampleRate: Double) {
        self.deviceUID = deviceUID
        self.sampleRate = sampleRate
        samples.reserveCapacity(Int(sampleRate * 12))
    }

    deinit {
        if let queue { AudioQueueDispose(queue, true) }
    }

    func start() throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var newQueue: AudioQueueRef?
        try caCheck(
            AudioQueueNewInputWithDispatchQueue(&newQueue, &format, 0, callbackQueue) { [weak self] queue, buffer, _, _, _ in
                self?.consume(buffer)
                AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            },
            "Couldn't open the microphone"
        )
        guard let newQueue else {
            throw NSError(domain: "iQualize", code: -301,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't open the microphone"])
        }
        queue = newQueue

        let uid = deviceUID as CFString
        try withExtendedLifetime(uid) {
            var ref = Unmanaged.passUnretained(uid)
            try caCheck(
                AudioQueueSetProperty(newQueue, kAudioQueueProperty_CurrentDevice, &ref,
                                      UInt32(MemoryLayout<Unmanaged<CFString>>.size)),
                "Couldn't select the microphone"
            )
        }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            try caCheck(AudioQueueAllocateBuffer(newQueue, UInt32(Self.bufferFrames * 4), &buffer),
                        "Couldn't allocate microphone buffers")
            if let buffer { AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil) }
        }
        try caCheck(AudioQueueStart(newQueue, nil), "Couldn't start the microphone")
    }

    /// Stops recording (idempotent) and returns everything recorded.
    func stop() -> [Float] {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// Peak level since the last call, for the live meter.
    func takePeakDBFS() -> Float {
        lock.lock()
        let peak = peakSinceRead
        peakSinceRead = 0
        lock.unlock()
        return peak > 0 ? 20 * log10(peak) : -120
    }

    private func consume(_ buffer: AudioQueueBufferRef) {
        let frames = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        let chunk = UnsafeBufferPointer(start: data, count: frames)
        var peak: Float = 0
        for v in chunk { peak = max(peak, abs(v)) }
        lock.lock()
        samples.append(contentsOf: chunk)
        peakSinceRead = max(peakSinceRead, peak)
        lock.unlock()
    }
}
