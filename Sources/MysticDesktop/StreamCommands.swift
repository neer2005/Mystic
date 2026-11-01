import SwiftUI

struct HostSessionActionKey: FocusedValueKey { typealias Value = () -> Void }
struct StreamHealthActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    /// Opens the focused stream window's health report; nil without a running stream.
    var streamHealthAction: (() -> Void)? {
        get { self[StreamHealthActionKey.self] }
        set { self[StreamHealthActionKey.self]=newValue }
    }
    /// Presents the focused window's Session and Graphics sheet; nil where it is unavailable.
    var hostSessionAction: (() -> Void)? {
        get { self[HostSessionActionKey.self] }
        set { self[HostSessionActionKey.self]=newValue }
    }
}

/// The saved shortcuts, for the Stream menu and the stream toolbar.
struct ShortcutMenuItems: View {
    let model: ConnectionModel
    var body: some View {
        ForEach(model.shortcuts.shortcuts.data) { shortcut in
            Button("\(shortcut.name) (\(shortcut.chord))") { model.sendShortcut(shortcut) }
                .disabled(!model.canSendShortcut)
        }
        if model.shortcuts.shortcuts.data.isEmpty { Text("No Saved Shortcuts") }
        Divider()
        SettingsLink { Text("Edit Shortcuts…") }
    }
}

/// Stream actions live in the menu bar; the stream toolbar keeps only the frequent ones.
/// While input is captured, keys go to the host, so these shortcuts work only after release.
public struct StreamCommands: Commands {
    let model: ConnectionModel
    @FocusedValue(\.hostSessionAction) private var showHostSession
    @FocusedValue(\.streamHealthAction) private var showHealth
    public init(model: ConnectionModel) { self.model=model }
    private var streaming: Bool { model.phase == .streaming }
    private var capture: StreamInputCapture? { model.inputCapture }
    public var body: some Commands {
        CommandGroup(after:.toolbar) {
            Button(model.showLatencyHUD ? "Hide Latency HUD" : "Show Latency HUD") { model.showLatencyHUD.toggle() }
                .keyboardShortcut("l",modifiers:[.option,.command])
        }
        CommandMenu("Stream") {
            Button("Control Desktop") { capture?.controlDesktop() }
                .disabled(capture?.available != true)
            Button("Capture Mouse") { capture?.captureMouse() }
                .keyboardShortcut("m",modifiers:[.control,.command])
                .disabled(capture?.available != true)
            // Shown for discoverability: the capture monitor handles this chord before menus see it.
            Button("Release Input") { capture?.release() }
                .keyboardShortcut(.escape,modifiers:[.control,.option,.shift])
                .disabled((capture?.mode ?? .released) == .released)
            Divider()
            Button(model.muted ? "Unmute Sound" : "Mute Sound") { model.muted.toggle() }
                .keyboardShortcut("m",modifiers:[.shift,.command])
            if model.microphoneEnabled {
                Button(model.microphoneMuted ? "Unmute Microphone" : "Mute Microphone") { model.microphoneMuted.toggle() }
                    .keyboardShortcut("m",modifiers:[.option,.shift,.command])
                    .disabled(!streaming)
            }
            Button("Retry Audio Output") { model.retryAudioOutput() }
                .disabled(!model.canRetryAudio)
            Divider()
            Menu("Send Shortcut") { ShortcutMenuItems(model:model) }
            Divider()
            Button("Send Clipboard Text to Host") { model.sendClipboardToHost() }
                .disabled(!model.canSendClipboard)
            Button("Copy Host Clipboard Text to Mac") { model.copyHostClipboard() }
                .disabled(!model.canReadClipboard)
            Divider()
            Button("Session and Graphics…") { showHostSession?() }
                .keyboardShortcut("i",modifiers:.command)
                .disabled(showHostSession == nil)
            Button("Why Did My Stream Stutter?…") { showHealth?() }
                .keyboardShortcut("h",modifiers:[.control,.command])
                .disabled(showHealth == nil)
            #if DEBUG
            Divider()
            Button("Test Video Recovery") { model.simulateVideoLoss() }
                .disabled(!streaming)
            #endif
        }
    }
}
