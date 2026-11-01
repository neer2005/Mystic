import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HostSessionActionKey: FocusedValueKey { typealias Value = () -> Void }
struct HostDetailsActionKey: FocusedValueKey { typealias Value = () -> Void }
struct StreamHealthActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    /// Opens the connected PC's details; nil without one.
    var hostDetailsAction: (() -> Void)? {
        get { self[HostDetailsActionKey.self] }
        set { self[HostDetailsActionKey.self]=newValue }
    }
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
    @FocusedValue(\.hostDetailsAction) private var showHostDetails
    @FocusedValue(\.streamHealthAction) private var showHealth
    public init(model: ConnectionModel) { self.model=model }
    private var streaming: Bool { model.phase == .streaming }
    private var capture: StreamInputCapture? { model.inputCapture }
    /// The last stream's per-second figures as CSV, in Nightjar's columns; kept after it ends.
    private func saveStatistics() {
        let panel=NSSavePanel()
        panel.allowedContentTypes=[.commaSeparatedText]
        panel.nameFieldStringValue="mystic-\(Int(Date().timeIntervalSince1970)).csv"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        if let error=model.saveStatistics(to:url) {
            let alert=NSAlert();alert.messageText="Could not save statistics.";alert.informativeText=error;alert.runModal()
        }
    }
    public var body: some Commands {
        CommandGroup(after:.help) {
            Button("Show Session Log in Finder") {
                if let file=model.sessionLogFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }.disabled(model.sessionLogFile == nil)
        }
        CommandGroup(after:.toolbar) {
            Button(model.showLatencyHUD ? "Hide Performance Overlay" : "Show Performance Overlay") { model.showLatencyHUD.toggle() }
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
            Button("Host Details…") { showHostDetails?() }.disabled(showHostDetails == nil)
            Button("Session and Graphics…") { showHostSession?() }
                .keyboardShortcut("i",modifiers:.command)
                .disabled(showHostSession == nil)
            Button("Why Did My Stream Stutter?…") { showHealth?() }
                .keyboardShortcut("h",modifiers:[.control,.command])
                .disabled(showHealth == nil)
            Button("Save Statistics…") { saveStatistics() }
                .disabled(!model.canSaveStatistics)
            #if DEBUG
            Divider()
            Button("Test Video Recovery") { model.simulateVideoLoss() }
                .disabled(!streaming)
            #endif
        }
    }
}
