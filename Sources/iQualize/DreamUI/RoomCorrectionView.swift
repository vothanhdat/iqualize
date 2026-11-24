import SwiftUI

/// The Room Correction wizard: set up the mic and level, measure one or more positions,
/// then tune and apply the fitted correction. All state lives in `RoomCorrectionModel` /
/// `RoomMeasurementSession`, so the views here only read and bind.
@available(macOS 14.2, *)
struct RoomCorrectionView: View {
    @Bindable var model: RoomCorrectionModel

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                Group {
                    switch model.step {
                    case .setup: RoomSetupStep(model: model, session: model.session)
                    case .measure: RoomMeasureStep(model: model, session: model.session)
                    case .correct: RoomCorrectStep(model: model)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var stepHeader: some View {
        HStack(spacing: 6) {
            ForEach(RoomCorrectionModel.Step.allCases) { step in
                Button(step.title) { model.step = step }
                    .buttonStyle(.borderless)
                    .font(.system(size: 13, weight: model.step == step ? .semibold : .regular))
                    .foregroundStyle(model.step == step ? Color.accentColor : Color.secondary)
                    .disabled(!model.canOpen(step) || model.session.isBusy)
                if step != RoomCorrectionModel.Step.allCases.last {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let error = model.session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = model.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let previous = RoomCorrectionModel.Step(rawValue: model.step.rawValue - 1) {
                Button("Back") { model.step = previous }
                    .disabled(model.session.isBusy)
            }
            if let next = RoomCorrectionModel.Step(rawValue: model.step.rawValue + 1) {
                Button("Next") { model.step = next }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canOpen(next) || model.session.isBusy)
            }
        }
    }
}

// MARK: - Step 1: Set up

@available(macOS 14.2, *)
private struct RoomSetupStep: View {
    let model: RoomCorrectionModel
    @Bindable var session: RoomMeasurementSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Room Correction plays a sweep through your speakers, records it with a microphone at your "
                 + "listening position, and builds an EQ that evens out how your room colors the sound — "
                 + "mostly booming or missing bass. It runs under every preset, for this output only.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            section("Speakers") {
                Text(session.outputDeviceName.isEmpty ? "No output device" : session.outputDeviceName)
                if let warning = session.outputWarning {
                    warningText(warning)
                }
                Picker("Measure", selection: $session.mode) {
                    Text("Both speakers together — one correction for both")
                        .tag(RoomMeasurementSession.MeasurementMode.together)
                    Text("Left and right separately — a correction for each")
                        .tag(RoomMeasurementSession.MeasurementMode.separate)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!session.positions.isEmpty || session.isBusy)
                if !session.positions.isEmpty {
                    note("To change this, remove the measurements on the Measure step first.")
                } else if session.mode == .separate {
                    note("Each sweep plays through one speaker at a time. Measure separately when the two "
                         + "speakers sit differently in the room — one near a wall or in a corner, say.")
                }
                if let existing = model.existingCorrection {
                    ExistingCorrectionRow(model: model, correction: existing)
                }
            }

            section("Microphone") {
                HStack {
                    Picker("Microphone", selection: $session.selectedInputUID) {
                        ForEach(session.inputDevices) { device in
                            Text(device.isDefault ? "\(device.name) (default)" : device.name)
                                .tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Button {
                        session.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh the device lists")
                    .disabled(session.isBusy)
                }
                if session.inputDevices.isEmpty {
                    warningText("No microphone found. Connect one, then refresh.")
                } else if let mic = session.selectedInput {
                    if mic.isBluetooth {
                        warningText("A Bluetooth headset mic switches the headset into call mode and records at "
                                    + "low quality. Use a wired or built-in microphone.")
                    } else if mic.isBuiltIn {
                        note("The built-in mic works, but it isn't flat and sits next to the speakers. A "
                             + "measurement mic (e.g. a USB miniDSP UMIK-1) placed at your seat is far more accurate.")
                    }
                }
                HStack {
                    if let calibration = session.calibration {
                        Label("Calibration: \(calibration.name)", systemImage: "checkmark.seal")
                        Button("Remove") { model.clearCalibration() }
                            .buttonStyle(.link)
                    } else {
                        Button("Load Calibration File…") { model.loadCalibration() }
                        Text("Optional — the .txt file that came with a measurement mic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(session.isBusy)
            }

            section("Level") {
                note("Pause any music: iQualize mutes other audio while it measures. Click Check Level and set "
                     + "your volume so the noise is clearly audible but comfortable — the sweep will play at the "
                     + "same loudness.")
                if session.permissionDenied {
                    HStack {
                        warningText("iQualize doesn't have microphone access.")
                        Button("Open Privacy Settings") { model.openMicrophonePrivacySettings() }
                    }
                }
                HStack(spacing: 12) {
                    if session.activity == .checkingLevel {
                        Button("Stop") { session.cancel() }
                    } else {
                        Button("Check Level") { session.checkLevel() }
                            .disabled(session.isBusy || session.selectedInput == nil)
                    }
                    LevelMeter(levelDBFS: session.activity == .idle
                               ? (session.levelReport?.peakDBFS ?? -120)
                               : session.liveLevelDBFS)
                        .frame(width: 220, height: 10)
                }
                if let report = session.levelReport {
                    levelVerdict(report)
                }
            }
        }
    }

    @ViewBuilder
    private func levelVerdict(_ report: RoomMeasurementSession.LevelReport) -> some View {
        let detail = String(format: "Peak %.0f dBFS, %.0f dB above the room's background noise.",
                            report.peakDBFS, report.rmsDBFS - report.noiseFloorDBFS)
        switch report.verdict {
        case .good:
            Label("Good level. \(detail)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .tooQuiet:
            Label("Too quiet — turn the volume up or move the mic closer, then check again. \(detail)",
                  systemImage: "speaker.wave.1")
                .foregroundStyle(.orange)
        case .tooLoud:
            Label("Too loud — the microphone is clipping. Turn the volume down and check again.",
                  systemImage: "speaker.wave.3.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Step 2: Measure

@available(macOS 14.2, *)
private struct RoomMeasureStep: View {
    let model: RoomCorrectionModel
    @Bindable var session: RoomMeasurementSession

    private var sweepSeconds: Int { session.mode == .together ? 8 : 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Put the microphone where your head usually is, pointing at the ceiling, and keep the room "
                 + "quiet. Each measurement takes about \(sweepSeconds) seconds"
                 + (session.mode == .separate ? " — the left speaker plays first, then the right" : "")
                 + ". Measuring 3–5 spots about 30 cm (1 ft) apart around your seat gives a correction that "
                 + "holds up as you move, rather than one tuned to a single point.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if session.activity == .measuring || session.activity == .analyzing {
                    Button("Stop") { session.cancel() }
                    ProgressView().controlSize(.small)
                    Text(progressText).foregroundStyle(.secondary)
                    LevelMeter(levelDBFS: session.liveLevelDBFS)
                        .frame(width: 160, height: 10)
                } else {
                    Button(session.positions.isEmpty ? "Measure" : "Measure Position \(session.positions.count + 1)") {
                        model.clearStatus()
                        session.measurePosition()
                    }
                    .disabled(session.isBusy || session.positions.count >= RoomMeasurementSession.maxPositions)
                    if session.positions.count >= RoomMeasurementSession.maxPositions {
                        Text("That's the maximum of \(RoomMeasurementSession.maxPositions) positions.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            CorrectionGraph(curves: graphCurves, emptyMessage: "Measured responses appear here.")
                .frame(height: 260)

            if !session.positions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.positions.enumerated()), id: \.element.id) { index, position in
                        HStack {
                            Text("Position \(index + 1)")
                            Text(String(format: "peak %.0f dBFS", position.peakDBFS))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if position.clipped {
                                Label("clipped", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            }
                            Spacer()
                            Button {
                                session.removePosition(id: position.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this position")
                            .disabled(session.isBusy)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
        }
    }

    private var progressText: String {
        if session.activity == .analyzing { return "Analyzing…" }
        let position = "position \(session.positions.count + 1)"
        switch session.measuringChannel {
        case .left: return "Measuring the left speaker, \(position)…"
        case .right: return "Measuring the right speaker, \(position)…"
        default: return "Measuring \(position)…"
        }
    }

    /// Positions faint, averages bold, all shifted so the midrange sits at 0 dB.
    private var graphCurves: [CorrectionGraph.Curve] {
        guard let overall = session.roomResponse(.both, smoothing: model.smoothing) else { return [] }
        let offset = -(overall.meanDB(from: 200, to: 2000) ?? 0)
        let channels: [(SpeakerChannel, Color, String)] = session.mode == .together
            ? [(.both, .orange, session.positions.count > 1 ? "Average" : "Measured")]
            : [(.left, .blue, "Left"), (.right, .orange, "Right")]
        var curves: [CorrectionGraph.Curve] = []
        for (channel, color, _) in channels {
            curves += model.positionResponses(channel).map {
                CorrectionGraph.Curve(curve: $0.offset(by: offset), color: color.opacity(0.25), width: 1)
            }
        }
        for (channel, color, label) in channels {
            if let average = session.roomResponse(channel, smoothing: model.smoothing) {
                curves.append(.init(curve: average.offset(by: offset), color: color, width: 2, label: label))
            }
        }
        return curves
    }
}

// MARK: - Step 3: Correct

@available(macOS 14.2, *)
private struct RoomCorrectStep: View {
    @Bindable var model: RoomCorrectionModel

    var body: some View {
        let fit = model.fit
        let shown = fit?.result(for: model.graphChannel)
        VStack(alignment: .leading, spacing: 16) {
            if fit?.isSplit == true {
                Picker("Speaker", selection: $model.graphChannel) {
                    Text("Left speaker").tag(SpeakerChannel.left)
                    Text("Right speaker").tag(SpeakerChannel.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            CorrectionGraph(curves: curves(shown), emptyMessage: "Measure at least one position first.",
                            shadeBelowHz: model.effectiveBassLimitHz)
                .frame(height: 260)

            if let fit {
                summary(fit)
            }

            bassLimitControls
                .disabled(fit == nil)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Correct up to")
                    Slider(value: Binding(
                        get: { log2(model.settings.upperHz) },
                        set: { model.settings.upperHz = (pow(2, $0) / 10).rounded() * 10 }
                    ), in: log2(CorrectionFitSettings.upperHzRange.lowerBound)...log2(CorrectionFitSettings.upperHzRange.upperBound))
                    Text(formatHz(model.settings.upperHz)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Above ~500 Hz a room's response changes within inches, so correcting higher only helps "
                         + "the exact spot you measured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
                GridRow {
                    Text("Bass lift")
                    Slider(value: $model.target.bassLiftDB, in: CorrectionTarget.bassLiftRange, step: 0.5)
                    Text(formatDB(model.target.bassLiftDB)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                GridRow {
                    Text("Treble tilt")
                    Slider(value: $model.target.trebleTiltDBPerOctave, in: CorrectionTarget.trebleTiltRange, step: 0.1)
                    Text(String(format: "%.1f dB/oct", model.target.trebleTiltDBPerOctave))
                        .monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                GridRow {
                    Text("Max boost")
                    Slider(value: $model.settings.maxBoostDB, in: CorrectionFitSettings.maxBoostRange, step: 0.5)
                    Text(formatDB(model.settings.maxBoostDB)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                if model.settings.maxBoostDB > CorrectionFitSettings.boostWarningDB {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Label("Boosts above \(Int(CorrectionFitSettings.boostWarningDB)) dB eat headroom — the "
                              + "peak limiter turns loud passages down to stop clipping — and push speakers hard. "
                              + "Use them for broad dips only.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellColumns(2)
                    }
                }
                GridRow {
                    Text("Max cut")
                    Slider(value: $model.settings.maxCutDB, in: CorrectionFitSettings.maxCutRange, step: 0.5)
                    Text(formatDB(-model.settings.maxCutDB)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                GridRow {
                    Text("Max Q")
                    Slider(value: $model.settings.maxQ, in: CorrectionFitSettings.maxQRange, step: 1)
                    Text(String(format: "Q %.0f", model.settings.maxQ)).monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Higher Q lets a narrow room mode get a narrow cut instead of a wide one. "
                         + "1/6-octave smoothing blurs peaks narrower than about Q 8, so use 1/12 to fit those.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
                GridRow {
                    Text("Max bands")
                    Stepper(value: $model.settings.maxBands, in: CorrectionFitSettings.maxBandsRange) {
                        Text("\(model.settings.maxBands)\(fit?.isSplit == true ? " per speaker" : "")").monospacedDigit()
                    }
                    Color.clear.frame(width: 70, height: 1)
                }
                GridRow {
                    Text("Smoothing")
                    Picker("Smoothing", selection: $model.smoothing) {
                        ForEach(RoomCorrectionModel.smoothingChoices, id: \.fraction) { choice in
                            Text(choice.label).tag(choice.fraction)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Color.clear.frame(width: 70, height: 1)
                }
            }
            .frame(maxWidth: 560)
            .disabled(fit == nil)

            if let shown, !shown.bands.isEmpty {
                bandList(shown.bands)
            }

            HStack(spacing: 12) {
                Button("Use for \(model.session.outputDeviceName)") { model.applyToDevice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(fit?.hasBands ?? false))
                Button("Save as Preset") { model.saveAsPreset() }
                    .disabled(!(fit?.hasBands ?? false))
                    .help("Save the bands as an ordinary preset you can edit, instead of a correction layer")
            }
            if let existing = model.existingCorrection {
                ExistingCorrectionRow(model: model, correction: existing)
            }
        }
    }

    // MARK: Bass limit

    private var bassLimitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Limit bass to what the speakers can play", isOn: $model.limitBass)
            if model.limitBass {
                HStack(spacing: 12) {
                    Text("Speakers reach down to")
                    Slider(value: Binding(
                        get: { log2(model.effectiveBassLimitHz ?? CorrectionTarget.bassRolloffRange.lowerBound) },
                        set: { model.bassLimitOverrideHz = CorrectionTarget.snappedBassRolloffHz(pow(2, $0)) }
                    ), in: log2(CorrectionTarget.bassRolloffRange.lowerBound)...log2(CorrectionTarget.bassRolloffRange.upperBound))
                    .frame(maxWidth: 260)
                    Stepper(value: Binding(
                        get: { model.effectiveBassLimitHz ?? CorrectionTarget.bassRolloffRange.lowerBound },
                        set: { model.bassLimitOverrideHz = CorrectionTarget.snappedBassRolloffHz($0) }
                    ), in: CorrectionTarget.bassRolloffRange, step: CorrectionTarget.bassRolloffStepHz) {
                        Text(model.effectiveBassLimitHz.map(formatHz) ?? "Full range")
                            .monospacedDigit()
                            .frame(width: 120, alignment: .leading)
                    }
                    .help("Step the limit by \(Int(CorrectionTarget.bassRolloffStepHz)) Hz")
                }
                HStack(spacing: 8) {
                    Text(model.detectedBassLimitHz.map { "Detected from the measurement: \(formatHz($0))" }
                         ?? "Detected from the measurement: full range, no limit needed")
                    if model.bassLimitOverrideHz != nil {
                        Button("Use Detected") { model.bassLimitOverrideHz = nil }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let limit = model.effectiveBassLimitHz, limit < CorrectionTarget.lowBassWarningHz {
                    lowBassWarning(limit)
                }
                if let limit = model.effectiveBassLimitHz {
                    Toggle(String(format: "Protect the speakers with a high-pass at %.0f Hz",
                                  limit * CorrectionFitSettings.protectionHighPassRatio),
                           isOn: $model.protectSpeakers)
                    Text("Small speakers can't play below this, and pushing them there only adds distortion and "
                         + "strain. The correction won't boost below it, and the high-pass keeps that bass from "
                         + "reaching the woofers at all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// Shown when the limit is below 50 Hz: few speakers play that low, and a correction
    /// there boosts what may be mic error rather than room.
    private func lowBassWarning(_ limit: Double) -> some View {
        var text = "Below \(Int(CorrectionTarget.lowBassWarningHz)) Hz only large speakers and subwoofers play "
            + "usefully. Make sure yours really reach \(formatHz(limit)): boosting bass they can't play adds "
            + "distortion and can damage small woofers."
        if let mic = model.session.selectedInput, mic.isBuiltIn || mic.isContinuity || mic.isBluetooth {
            text += " The \(mic.name) can't measure this low reliably either, so the correction down here "
                + "may follow the mic rather than your room — a measurement mic fixes that."
        }
        return Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Summary and bands

    @ViewBuilder
    private func summary(_ fit: RoomCorrectionModel.RoomFit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !fit.hasBands {
                Label("Nothing to correct: the room is already within about 1 dB of the target in this range.",
                      systemImage: "checkmark.circle")
            } else if let right = fit.right {
                Text("Left: \(describe(fit.left)) · Right: \(describe(right))")
            } else {
                Text(describe(fit.left))
            }
            if let difference = fit.rightLouderByDB, abs(difference) >= 1 {
                Text(String(format: "The %@ speaker plays %.1f dB louder at your seat. EQ can't fix overall level — "
                            + "use the Balance slider in the EQ window to even it out.",
                            difference > 0 ? "right" : "left", abs(difference)))
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func describe(_ result: CorrectionFitter.Result) -> String {
        let bells = result.bands.filter { $0.filterType == .parametric }.count
        return "\(bells) band\(bells == 1 ? "" : "s"), " + String(format: "±%.1f dB from target", result.residualRMSDB)
    }

    private func bandList(_ bands: [EQBand]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                HStack(spacing: 16) {
                    Text(formatHz(Double(band.frequency))).frame(width: 80, alignment: .trailing)
                    if band.filterType == .highPass {
                        Text("high-pass, 12 dB/oct").frame(width: 156, alignment: .leading)
                    } else {
                        Text(formatDB(Double(band.gain))).frame(width: 70, alignment: .trailing)
                        Text(String(format: "Q %.2f", octavesToQ(Double(band.bandwidth)))).frame(width: 70, alignment: .trailing)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func curves(_ result: CorrectionFitter.Result?) -> [CorrectionGraph.Curve] {
        guard let result else { return [] }
        return [
            .init(curve: result.aligned, color: .orange.opacity(0.8), width: 1.5, label: "Measured"),
            .init(curve: model.effectiveTarget.curve(), color: .secondary, width: 1, dash: [4, 3], label: "Target"),
            .init(curve: result.correction, color: .accentColor, width: 2, label: "Correction"),
            .init(curve: result.predicted, color: .green, width: 2, label: "Predicted"),
        ]
    }
}

// MARK: - Shared pieces

@available(macOS 14.2, *)
private struct ExistingCorrectionRow: View {
    let model: RoomCorrectionModel
    let correction: RoomCorrection

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Current correction", isOn: Binding(
                get: { correction.isEnabled },
                set: { model.setExistingCorrectionEnabled($0) }
            ))
            Text("\(correction.bandCount) bands\(correction.isSplit ? " (left and right)" : ""), measured "
                 + correction.createdAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
            Button("Remove") { model.removeExistingCorrection() }
                .buttonStyle(.link)
        }
        .font(.callout)
    }
}

@available(macOS 14.2, *)
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        content()
    }
}

private func warningText(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
}

private func note(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

private func formatHz(_ hz: Double) -> String {
    hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
}

private func formatDB(_ db: Double) -> String {
    String(format: "%+.1f dB", db)
}

/// Horizontal mic level bar, −60…0 dBFS, turning orange near clipping.
struct LevelMeter: View {
    let levelDBFS: Float

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(max(0, min(1, (levelDBFS + 60) / 60)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(levelDBFS > -3 ? Color.red : levelDBFS > -12 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .accessibilityLabel("Microphone level")
        .accessibilityValue(levelDBFS > -120 ? String(format: "%.0f dBFS", levelDBFS) : "silent")
    }
}

/// Log-frequency plot of measurement curves, 20 Hz–20 kHz, with a symmetric dB axis that
/// grows to fit. `shadeBelowHz` greys out the bass the speakers can't play.
struct CorrectionGraph: View {
    struct Curve {
        var curve: FrequencyCurve
        var color: Color
        var width: CGFloat
        var dash: [CGFloat] = []
        var label: String?
    }

    let curves: [Curve]
    var emptyMessage: String = ""
    var shadeBelowHz: Double?

    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in draw(into: &ctx, size: size) }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                .overlay {
                    if curves.isEmpty {
                        Text(emptyMessage).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Frequency response graph")
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(curves.enumerated()), id: \.offset) { _, curve in
                if let label = curve.label {
                    HStack(spacing: 5) {
                        Capsule().fill(curve.color).frame(width: 14, height: 3)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let shadeBelowHz, !curves.isEmpty {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)).frame(width: 14, height: 8)
                    Text("Below the speakers' reach (\(Int(shadeBelowHz.rounded())) Hz)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dbRange: Double {
        var peak = 6.0
        for c in curves {
            for (f, v) in zip(c.curve.frequencies, c.curve.dB) where f >= 20 && f <= 20000 {
                peak = max(peak, abs(v))
            }
        }
        return max(12, ((peak + 2) / 6).rounded(.up) * 6)
    }

    private func draw(into ctx: inout GraphicsContext, size: CGSize) {
        let range = dbRange
        let inset: CGFloat = 28
        let plot = CGRect(x: inset, y: 8, width: max(1, size.width - inset - 8), height: max(1, size.height - 26))
        func x(_ f: Double) -> CGFloat { plot.minX + CGFloat(log(f / 20) / log(1000)) * plot.width }
        func y(_ db: Double) -> CGFloat { plot.midY - CGFloat(db / range) * plot.height / 2 }

        if let shadeBelowHz, !curves.isEmpty, shadeBelowHz > 20 {
            let shade = CGRect(x: plot.minX, y: plot.minY, width: x(min(shadeBelowHz, 20000)) - plot.minX,
                               height: plot.height)
            ctx.fill(Path(shade), with: .color(.secondary.opacity(0.12)))
        }

        for f in Self.gridFrequencies {
            var p = Path()
            p.move(to: CGPoint(x: x(f), y: plot.minY))
            p.addLine(to: CGPoint(x: x(f), y: plot.maxY))
            ctx.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: x(f), y: plot.maxY + 9))
        }
        var db = -range
        while db <= range + 0.01 {
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: y(db)))
            p.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
            ctx.stroke(p, with: .color(.secondary.opacity(db == 0 ? 0.4 : 0.15)), lineWidth: db == 0 ? 1 : 0.5)
            ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: inset / 2, y: y(db)))
            db += 6
        }

        ctx.clip(to: Path(plot))
        for c in curves {
            var path = Path()
            var started = false
            for (f, v) in zip(c.curve.frequencies, c.curve.dB) where f >= 20 && f <= 20000 {
                let point = CGPoint(x: x(f), y: y(v))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            ctx.stroke(path, with: .color(c.color),
                       style: StrokeStyle(lineWidth: c.width, lineJoin: .round, dash: c.dash))
        }
    }
}
