import SwiftUI
import AppKit

/// The focused window's full-screen state and toggle, for the View menu.
struct FullScreenToggle {
    let isFullScreen: Bool
    let toggle: () -> Void
}
struct FullScreenToggleKey: FocusedValueKey { typealias Value = FullScreenToggle }
extension FocusedValues {
    var fullScreenToggle: FullScreenToggle? {
        get { self[FullScreenToggleKey.self] }
        set { self[FullScreenToggleKey.self]=newValue }
    }
}

/// AppKit's automatic Enter Full Screen item never appeared while the stream window was in
/// front, although that window supports full screen. Mystic owns the item instead and, like
/// its other commands, follows the focused window. AppKit's item is turned off to avoid a
/// duplicate in the library window.
public struct FullScreenCommands: Commands {
    @FocusedValue(\.fullScreenToggle) private var fullScreen
    public init() {}
    public var body: some Commands {
        CommandGroup(after:.sidebar) {
            Button(fullScreen?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen") { fullScreen?.toggle() }
                // SwiftUI cannot show the Globe-F of AppKit's item; AppKit also honors ⌃⌘F.
                .keyboardShortcut("f",modifiers:[.control,.command])
                .disabled(fullScreen == nil)
        }
    }
    /// Call from the App's initializer: AppKit reads this before the delegate's launch callbacks.
    /// A registered default, so nothing is written to the user's preferences.
    public static func suppressAppKitItem() {
        UserDefaults.standard.register(defaults:["NSFullScreenMenuItemEverywhere":false])
    }
}

/// Publishes the hosting window's full-screen state and toggle while it is focused.
private struct FullScreenCommandTarget: ViewModifier {
    @State private var window: NSWindow?
    @State private var isFullScreen=false
    private func update(_ notification: Notification) {
        if let window,notification.object as? NSWindow === window { isFullScreen=window.isStreamFullScreen }
    }
    func body(content: Content) -> some View {
        content
            .background(WindowReader { window=$0;isFullScreen=$0?.isStreamFullScreen == true })
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didEnterFullScreenNotification)) { update($0) }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didExitFullScreenNotification)) { update($0) }
            .onReceive(NotificationCenter.default.publisher(for:NotchFullScreen.didChangeNotification)) { update($0) }
            .focusedSceneValue(\.fullScreenToggle,window.map { window in
                FullScreenToggle(isFullScreen:isFullScreen) { [weak window] in window?.toggleFullScreen(nil) }
            })
    }
}
extension View {
    /// Makes this window the target of View → Enter/Exit Full Screen while it is focused.
    func fullScreenCommandTarget() -> some View { modifier(FullScreenCommandTarget()) }
}

/// Hands the hosting window to the view once it is in one.
struct WindowReader: NSViewRepresentable {
    let receive: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(receive:receive) }
    func updateNSView(_ view: WindowProbe,context: Context) {}
}
final class WindowProbe: NSView {
    let receive: @MainActor (NSWindow?) -> Void
    init(receive: @escaping @MainActor (NSWindow?) -> Void) { self.receive=receive;super.init(frame:.zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in guard let self else { return };receive(window) }
    }
}
