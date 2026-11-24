import SwiftUI

/// Native sidebar preset list — an additional way to browse/select presets alongside the
/// toolbar's preset-picker popup menu (`DreamToolbarController.showPresetMenu`). Selection
/// routes through `vm.loadPreset(id:)` so the unsaved-changes confirmation gate
/// (`confirmDiscardIfNeeded`) applies exactly as it does for the toolbar menu.
///
/// Each group collapses from its header (remembered across launches), and each row offers
/// Delete on hover and in its context menu, with the toolbar's confirmation (`vm.deletePreset`),
/// plus Rename… in the context menu (`vm.renamePreset`).
@available(macOS 14.2, *)
@MainActor
struct PresetSidebarView: View {
    @Bindable var vm: DreamViewModel

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let resolvedScheme: ColorScheme = vm.theme.colorScheme ?? systemScheme
        let theme = DreamTheme(scheme: resolvedScheme)

        List(selection: Binding(
            get: { vm.activePresetID },
            set: { newID in if let newID { vm.loadPreset(id: newID) } }
        )) {
            if !vm.presetStore.favoritePresets.isEmpty {
                group(.favorites, title: "Favorites", presets: vm.presetStore.favoritePresets)
            }
            group(.builtIn, title: "Built-in", presets: vm.presetStore.allPresets.filter(\.isBuiltIn))
            if !vm.presetStore.customPresets.isEmpty {
                group(.custom, title: "Custom", presets: vm.presetStore.customPresets)
            }
        }
        .listStyle(.sidebar)
        .environment(\.dreamTheme, theme)
        .preferredColorScheme(vm.theme.colorScheme)
    }

    @ViewBuilder
    private func group(_ group: PresetGroup, title: String, presets: [EQPresetData]) -> some View {
        Section(isExpanded: Binding(
            get: { !vm.collapsedPresetGroups.contains(group) },
            set: { vm.setPresetGroup(group, expanded: $0) }
        )) {
            ForEach(presets) { preset in
                PresetSidebarRow(
                    name: preset.name,
                    isFavorite: vm.presetStore.isFavorite(preset.id),
                    canDelete: vm.canDeletePreset(id: preset.id),
                    onToggleFavorite: { vm.presetStore.toggleFavorite(preset.id) },
                    onRename: { vm.renamePreset(id: preset.id) },
                    onDelete: { vm.deletePreset(id: preset.id) }
                )
                .tag(preset.id)
            }
        } header: {
            Text(title)
        }
    }
}

/// One preset in the sidebar: name, a trash button while hovered (never for Flat), and the
/// favorite star. The context menu offers the same actions.
@available(macOS 14.2, *)
private struct PresetSidebarRow: View {
    let name: String
    let isFavorite: Bool
    let canDelete: Bool
    let onToggleFavorite: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if canDelete && hover {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete Preset…")
                .accessibilityLabel("Delete \(name)")
            }
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color(nsColor: .controlAccentColor) : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isFavorite ? 1 : 0.35)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", action: onToggleFavorite)
            Button("Rename…", action: onRename)
            if canDelete {
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            }
        }
    }
}
