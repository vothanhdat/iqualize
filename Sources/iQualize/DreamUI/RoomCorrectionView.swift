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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Put the microphone where your head usually is, pointing at the ceiling, and keep the room "
                 + "quiet. Each sweep takes about 8 seconds. Measuring 3–5 spots about 30 cm (1 ft) apart around "
                 + "your seat gives a correction that holds up as you move, rather than one tuned to a single point.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if session.activity == .measuring || session.activity == .analyzing {
                    Button("Stop") { session.cancel() }
                    ProgressView().controlSize(.small)
                    Text(session.activity == .measuring ? "Measuring position \(session.positions.count + 1)…" : "Analyzing…")
                        .foregroundStyle(.secondary)
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

    /// Positions faint, their average bold, all shifted so the average's midrange sits at 0 dB.
    private var graphCurves: [CorrectionGraph.Curve] {
        guard let average = session.roomResponse(smoothing: model.smoothing) else { return [] }
        let offset = -(average.meanDB(from: 200, to: 2000) ?? 0)
        var curves = model.positionResponses.map {
            CorrectionGraph.Curve(curve: $0.offset(by: offset), color: .orange.opacity(0.3), width: 1)
        }
        if session.positions.count > 1 {
            curves.append(.init(curve: average.offset(by: offset), color: .orange, width: 2, label: "Average"))
        } else {
            curves.append(.init(curve: average.offset(by: offset), color: .orange, width: 2, label: "Measured"))
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
        VStack(alignment: .leading, spacing: 16) {
            CorrectionGraph(curves: curves(fit), emptyMessage: "Measure at least one position first.")
                .frame(height: 260)

            if let fit {
                summary(fit)
            }

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
                GridRow {
                    Text("Max cut")
                    Slider(value: $model.settings.maxCutDB, in: CorrectionFitSettings.maxCutRange, step: 0.5)
                    Text(formatDB(-model.settings.maxCutDB)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                GridRow {
                    Text("Max bands")
                    Stepper(value: $model.settings.maxBands, in: CorrectionFitSettings.maxBandsRange) {
                        Text("\(model.settings.maxBands)").monospacedDigit()
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

            if let fit, !fit.bands.isEmpty {
                bandList(fit.bands)
            }

            HStack(spacing: 12) {
                Button("Use for \(model.session.outputDeviceName)") { model.applyToDevice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(fit?.bands.isEmpty ?? true)
                Button("Save as Preset") { model.saveAsPreset() }
                    .disabled(fit?.bands.isEmpty ?? true)
                    .help("Save the bands as an ordinary preset you can edit, instead of a correction layer")
            }
            if let existing = model.existingCorrection {
                ExistingCorrectionRow(model: model, correction: existing)
            }
        }
    }

    @ViewBuilder
    private func summary(_ fit: CorrectionFitter.Result) -> some View {
        if fit.bands.isEmpty {
            Label("Nothing to correct: the room is already within about 1 dB of the target in this range.",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Text("\(fit.bands.count) band\(fit.bands.count == 1 ? "" : "s") · remaining deviation "
                 + String(format: "±%.1f dB", fit.residualRMSDB) + " RMS")
                .foregroundStyle(.secondary)
        }
    }

    private func bandList(_ bands: [EQBand]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                HStack(spacing: 16) {
                    Text(formatHz(Double(band.frequency))).frame(width: 80, alignment: .trailing)
                    Text(formatDB(Double(band.gain))).frame(width: 70, alignment: .trailing)
                    Text(String(format: "Q %.2f", octavesToQ(Double(band.bandwidth)))).frame(width: 70, alignment: .trailing)
                }
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func curves(_ fit: CorrectionFitter.Result?) -> [CorrectionGraph.Curve] {
        guard let fit else { return [] }
        return [
            .init(curve: fit.aligned, color: .orange.opacity(0.8), width: 1.5, label: "Measured"),
            .init(curve: model.target.curve(), color: .secondary, width: 1, dash: [4, 3], label: "Target"),
            .init(curve: fit.correction, color: .accentColor, width: 2, label: "Correction"),
            .init(curve: fit.predicted, color: .green, width: 2, label: "Predicted"),
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
            Text("\(correction.bands.count) bands, measured \(correction.createdAt.formatted(date: .abbreviated, time: .shortened))")
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
/// grows to fit.
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
