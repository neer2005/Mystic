import SwiftUI

struct LibrarySearchActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var librarySearchAction: (() -> Void)? {
        get { self[LibrarySearchActionKey.self] }
        set { self[LibrarySearchActionKey.self]=newValue }
    }
}

/// The Find command follows the focused library window, not Settings or a stream.
public struct LibraryCommands: Commands {
    @FocusedValue(\.librarySearchAction) private var findApps
    public init() {}
    public var body: some Commands {
        CommandGroup(after:.textEditing) {
            Button("Find Apps") { findApps?() }
                .keyboardShortcut("f",modifiers:.command)
                .disabled(findApps == nil)
        }
    }
}
