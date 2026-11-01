import SwiftUI

struct LibrarySearchActionKey: FocusedValueKey { typealias Value = () -> Void }
/// Actions for the focused library window's current selection. A nil member is unavailable.
struct LibraryMenuActions {
    var play: (title: String,action: () -> Void)?
    var favourite: (isFavourite: Bool,toggle: () -> Void)?
    var refresh: (() -> Void)?
    /// Only the host library has a list layout; Home is always a grid.
    var layout: Binding<String>?
}
struct LibraryMenuActionsKey: FocusedValueKey { typealias Value = LibraryMenuActions }
extension FocusedValues {
    var librarySearchAction: (() -> Void)? {
        get { self[LibrarySearchActionKey.self] }
        set { self[LibrarySearchActionKey.self]=newValue }
    }
    var libraryMenuActions: LibraryMenuActions? {
        get { self[LibraryMenuActionsKey.self] }
        set { self[LibraryMenuActionsKey.self]=newValue }
    }
}

/// Library commands follow the focused library window, not Settings or a stream.
public struct LibraryCommands: Commands {
    @FocusedValue(\.librarySearchAction) private var findApps
    @FocusedValue(\.libraryMenuActions) private var actions
    public init() {}
    public var body: some Commands {
        CommandGroup(after:.textEditing) {
            Button("Find Apps") { findApps?() }
                .keyboardShortcut("f",modifiers:.command)
                .disabled(findApps == nil)
        }
        CommandGroup(before:.toolbar) {
            // An inline picker, present only for the host library (Home has no list layout).
            // A Toggle anywhere in the View menu makes AppKit drop its Enter Full Screen item,
            // and a menu picker cannot be disabled, so the options come and go instead.
            if let layout=actions?.layout {
                Picker("Library View",selection:layout) {
                    Text("as Grid").tag("grid").keyboardShortcut("1",modifiers:.command)
                    Text("as List").tag("list").keyboardShortcut("2",modifiers:.command)
                }.pickerStyle(.inline)
                Divider()
            }
        }
        CommandMenu("Library") {
            Button(actions?.play?.title ?? "Start Stream") { actions?.play?.action() }
                .disabled(actions?.play == nil)
            Button(actions?.favourite?.isFavourite == true ? "Remove from Favourites" : "Add to Favourites") { actions?.favourite?.toggle() }
                .disabled(actions?.favourite == nil)
            Divider()
            Button("Refresh Library") { actions?.refresh?() }
                .keyboardShortcut("r",modifiers:.command)
                .disabled(actions?.refresh == nil)
        }
    }
}
