import AppKit
import SwiftUI

/// A Mac search field inside the library column, so it lines up with the games it filters. In the
/// toolbar of this three-column window, macOS placed it across the columns' divider.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// Changing it moves the keyboard into the field, for Find in the menu.
    let focus: Int
    func makeNSView(context: Context) -> NSSearchField {
        let field=Field()
        field.delegate=context.coordinator
        field.sendsSearchStringImmediately=true
        field.controlSize = .regular
        return field
    }
    func updateNSView(_ field: NSSearchField,context: Context) {
        context.coordinator.text=$text
        if field.stringValue != text { field.stringValue=text }
        field.placeholderString=prompt
        if context.coordinator.focus != focus {
            context.coordinator.focus=focus
            DispatchQueue.main.async { (field as? Field)?.focusNow() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(text:$text,focus:focus) }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focus: Int
        init(text: Binding<String>,focus: Int) { self.text=text;self.focus=focus }
        func controlTextDidChange(_ note: Notification) {
            guard let field=note.object as? NSSearchField else { return }
            text.wrappedValue=field.stringValue
        }
    }
}

/// Takes the keyboard only when asked: a click, Tab, or Find. Otherwise AppKit would hand it the
/// keyboard when the window opens, and the game grid, which selects on getting it, would show nothing.
private final class Field: NSSearchField {
    private var asked=false
    override var acceptsFirstResponder: Bool {
        asked || NSApp.currentEvent.map { [.leftMouseDown,.keyDown].contains($0.type) } == true
    }
    func focusNow() { asked=true;window?.makeFirstResponder(self);asked=false }
}
