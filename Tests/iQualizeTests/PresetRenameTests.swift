import XCTest
@testable import iQualize

@available(macOS 14.2, *)
@MainActor
final class PresetRenameTests: XCTestCase {
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

    private func makeViewModel() -> (DreamViewModel, PresetStore, AudioEngine) {
        let engine = AudioEngine()
        let presets = PresetStore(userDefaults: defaults)
        let vm = DreamViewModel(audioEngine: engine, presetStore: presets,
                                settings: SettingsStore(userDefaults: defaults),
                                correctionStore: RoomCorrectionStore(userDefaults: defaults))
        return (vm, presets, engine)
    }

    private func customPreset(_ name: String) -> EQPresetData {
        EQPresetData(id: UUID(), name: name, bands: [EQBand(frequency: 100, gain: 3)], isBuiltIn: false)
    }

    // MARK: - Name rules

    func testNameIsTrimmed() {
        let preset = customPreset("Old")
        XCTAssertEqual(try DreamViewModel.validatedPresetName("  Studio  ", renaming: preset.id, among: [preset]).get(),
                       "Studio")
    }

    func testEmptyNameIsRejected() {
        let preset = customPreset("Old")
        XCTAssertEqual(DreamViewModel.validatedPresetName("   ", renaming: preset.id, among: [preset]),
                       .failure(.empty))
    }

    func testAnotherPresetsNameIsRejectedIgnoringCase() {
        let preset = customPreset("Old")
        let other = customPreset("Studio")
        XCTAssertEqual(DreamViewModel.validatedPresetName("studio", renaming: preset.id, among: [preset, other]),
                       .failure(.taken("Studio")))
    }

    func testKeepingOrRecasingItsOwnNameIsAllowed() {
        let preset = customPreset("Studio")
        XCTAssertEqual(try DreamViewModel.validatedPresetName("STUDIO", renaming: preset.id, among: [preset]).get(),
                       "STUDIO")
    }

    // MARK: - Applying

    func testRenamingACustomPresetSavesTheNewName() {
        let (vm, presets, _) = makeViewModel()
        let preset = customPreset("My EQ")
        presets.saveCustomPreset(preset)

        vm.applyRename(id: preset.id, to: "Studio Monitors")

        XCTAssertEqual(presets.preset(for: preset.id)?.name, "Studio Monitors")
        XCTAssertEqual(PresetStore(userDefaults: defaults).preset(for: preset.id)?.name, "Studio Monitors",
                       "the new name persists")
        XCTAssertEqual(presets.preset(for: preset.id)?.bands, preset.bands)
    }

    /// Renaming the preset you're editing changes only its name: the unsaved band edits stay
    /// in the editor and stay unsaved.
    func testRenamingTheActivePresetKeepsUnsavedEdits() {
        let (vm, presets, engine) = makeViewModel()
        let preset = customPreset("My EQ")
        presets.saveCustomPreset(preset)
        engine.activePreset = preset
        vm.syncFromAudioEngine(initial: true)

        var edited = preset
        edited.bands = [EQBand(frequency: 100, gain: 9)]
        engine.activePreset = edited
        vm.isModified = true

        vm.applyRename(id: preset.id, to: "Studio")

        XCTAssertEqual(vm.presetName, "Studio")
        XCTAssertEqual(engine.activePreset.name, "Studio")
        XCTAssertEqual(engine.activePreset.bands, edited.bands, "the edit is still playing")
        XCTAssertTrue(vm.isModified, "the edit is still unsaved")
        XCTAssertEqual(presets.preset(for: preset.id)?.bands, preset.bands, "the saved bands are untouched")
    }

    func testRenamingABuiltInIsAnEditResetCanUndo() throws {
        let (vm, presets, _) = makeViewModel()
        let builtIn = EQPresetData.bassBoost

        vm.applyRename(id: builtIn.id, to: "Bass Heavy")
        XCTAssertEqual(presets.preset(for: builtIn.id)?.name, "Bass Heavy")
        XCTAssertTrue(presets.hasOverride(builtIn.id))

        presets.resetBuiltInToOriginal(id: builtIn.id)
        XCTAssertEqual(presets.preset(for: builtIn.id)?.name, builtIn.name)
    }

    func testRenamingToTheSameNameChangesNothing() {
        let (vm, presets, _) = makeViewModel()
        let builtIn = EQPresetData.bassBoost
        vm.applyRename(id: builtIn.id, to: builtIn.name)
        XCTAssertFalse(presets.hasOverride(builtIn.id))
    }
}
