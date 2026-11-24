import AppKit
import SwiftUI

/// Hosts the Room Correction wizard (`RoomCorrectionView`), using the same
/// `NSWindowController` + `NSHostingView` bridge as `PresetBrowserWindowController`.
/// Closing the window stops any sweep in progress, so a closed window can never keep
/// system audio muted.
@available(macOS 14.2, *)
@MainActor
final class RoomCorrectionWindowController: NSWindowController, NSWindowDelegate {
    private let model: RoomCorrectionModel

    init(audioEngine: AudioEngine, presetStore: PresetStore, correctionStore: RoomCorrectionStore) {
        model = RoomCorrectionModel(audioEngine: audioEngine, presetStore: presetStore,
                                    correctionStore: correctionStore)
        let window = ShortcutAwareWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: true
        )
        window.title = "Room Correction"
        window.minSize = NSSize(width: 640, height: 560)
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let host = NSHostingView(rootView: RoomCorrectionView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.contentView = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Picks up output or microphone changes made while the window was in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        if !model.session.isBusy {
            model.session.refreshDevices()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.session.cancel()
    }
}
