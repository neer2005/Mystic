import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MysticCore

/// Settings → Keyboard: the layout report and saved key shortcuts.
struct KeyboardSettingsView: View {
    @Bindable var model: ConnectionModel
    @State private var editing: ShortcutDraft?
    private var store: KeyShortcutsStore { model.shortcuts }
    var body: some View {
        Form {
            Section("Shortcuts") {
                if store.shortcuts.data.isEmpty {
                    Text("No saved shortcuts. Add one for keys macOS keeps for itself, such as WIN + TAB or CTRL + ALT + DELETE.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.shortcuts.data) { shortcut in
                    HStack {
                        VStack(alignment:.leading) {
                            Text(shortcut.name)
                            Text(shortcut.chord).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing=ShortcutDraft(id:shortcut.id,name:shortcut.name,chord:shortcut.chord) }
                        Button("Remove",role:.destructive) { store.remove(id:shortcut.id) }
                    }
                }
                HStack {
                    Button("Add Shortcut…") { editing=ShortcutDraft() }
                        .disabled(store.shortcuts.data.count >= KeyShortcuts.maxShortcuts)
                    Spacer()
                    Button("Import…",action:importFile)
                    Button("Export…",action:exportFile).disabled(store.shortcuts.data.isEmpty)
                }
                if let error=store.error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Send them from Stream → Send Shortcut. Files use the format of Nightjar and Moonlight on Android, so an exported file imports there too. Importing replaces every saved shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                Text("Mystic sends where each key is, not what it types. Hosts that support it are told this Mac's keyboard layout when a stream starts and whenever you switch layouts, so the PC types with the same one.")
                    .foregroundStyle(.secondary)
                Text("Text from the emoji picker, Character Viewer or dictation goes to a text field focused on the host.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item:$editing) { draft in ShortcutEditor(draft:draft,store:store) }
    }
    private func importFile() {
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else { return }
        store.importFile(url)
    }
    private func exportFile() {
        let panel=NSSavePanel()
        panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Mystic Shortcuts.json"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        _ = store.exportFile(url)
    }
}

struct ShortcutDraft: Identifiable {
    var id: String?
    var name=""
    var chord=""
}

private struct ShortcutEditor: View {
    @State var draft: ShortcutDraft
    let store: KeyShortcutsStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        Form {
            TextField("Name",text:$draft.name,prompt:Text("Task View"))
            TextField("Keys",text:$draft.chord,prompt:Text("WIN + TAB"))
                .font(.body.monospaced())
            Text("Join up to eight keys with +: letters and digits, F1 to F24, CTRL, SHIFT, ALT, WIN, TAB, ESC, ENTER, DELETE, arrows such as LEFT, and Android's other key names.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width:420)
        .toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement:.confirmationAction) {
                Button("Save") {
                    if store.save(id:draft.id,name:draft.name,chord:draft.chord) { dismiss() } else { error=store.error }
                }
            }
        }
    }
}
