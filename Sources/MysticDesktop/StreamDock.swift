import AppKit

/// Hides the Dock outright while a full-screen stream has the Mac's input, as the HIG allows
/// for games ("Going full screen": except in games, let people reveal the Dock). Without it a
/// pointer that reaches the bottom edge in desktop control slides the Dock over the game.
///
/// Only the Dock changes. AppKit allows `hideMenuBar` only without `autoHideToolbar`, and the
/// stream's toolbar must keep sliding down with the menu bar at the top edge, so the menu bar
/// stays auto-hidden. Releasing input (⌃⌥⇧Esc) gives the Dock back at once. Presentation
/// options change no pixels in the window, so the display path and its delay are untouched.
@MainActor
enum StreamDock {
    /// The options to use for a stream window; nil leaves the app's options as they are.
    static func options(_ current: NSApplication.PresentationOptions,fullScreen: Bool,controlling: Bool) -> NSApplication.PresentationOptions? {
        var next=current
        if fullScreen && controlling {
            // `hideDock` and `autoHideDock` are mutually exclusive.
            guard !current.contains(.hideDock) else { return nil }
            next.remove(.autoHideDock);next.insert(.hideDock)
        } else {
            guard current.contains(.hideDock) else { return nil }
            next.remove(.hideDock)
            // An auto-hidden menu bar needs the Dock hidden one way or the other.
            if fullScreen || next.contains(.autoHideMenuBar) { next.insert(.autoHideDock) }
        }
        return next
    }
    static func update(window: NSWindow?,controlling: Bool) {
        let fullScreen=window?.isStreamFullScreen == true && window?.isKeyWindow == true
        if let next=options(NSApp.presentationOptions,fullScreen:fullScreen,controlling:controlling) {
            NSApp.presentationOptions=next
        }
    }
}
