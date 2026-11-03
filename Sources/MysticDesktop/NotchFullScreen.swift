import AppKit
import ObjectiveC

/// Full screen that reaches the top of a notched MacBook display, as moonlight-qt does for a
/// stream made for the whole panel (3024 × 1964 on the 14-inch, 3456 × 2234 on the 16-inch).
///
/// AppKit's full screen always stops below the camera housing: the window gets the safe area
/// (1512 × 950 points of 1512 × 982 on the 14-inch), so a full-panel picture is pillarboxed.
/// Titled windows are also clamped below it however their frame is set. Like SDL's non-Spaces
/// full screen, which moonlight-qt picks for these resolutions, the window instead turns
/// borderless, covers the screen's whole frame and hides the menu bar and Dock while Mystic is
/// active. The camera hides a strip at the top center of the picture, as on the host's panel.
///
/// The window also stays in its Space rather than getting one of its own. Every other stream,
/// and every non-notched screen, keeps AppKit's full screen.
@MainActor
final class NotchFullScreen {
    static let didChangeNotification=Notification.Name("MysticNotchFullScreenDidChange")
    private weak var window: NSWindow?
    private let videoSize: @MainActor () -> CGSize
    private var saved: (style: NSWindow.StyleMask,frame: NSRect,options: NSApplication.PresentationOptions)?
    private var observers: [any NSObjectProtocol]=[]
    private init(window: NSWindow,videoSize: @escaping @MainActor () -> CGSize) { self.window=window;self.videoSize=videoSize }

    /// Routes the window's full-screen toggle (green button, View menu, ⌃⌘F) through Mystic.
    /// `videoSize` is the decoded picture in pixels, zero before the first frame.
    static func install(on window: NSWindow,videoSize: @escaping @MainActor () -> CGSize) {
        if controller(window) == nil {
            objc_setAssociatedObject(window,&controllerKey,NotchFullScreen(window:window,videoSize:videoSize),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        adoptKeyableClass(window)
    }
    static func isActive(_ window: NSWindow) -> Bool { controller(window)?.saved != nil }
    private static func controller(_ window: NSWindow) -> NotchFullScreen? {
        objc_getAssociatedObject(window,&controllerKey) as? NotchFullScreen
    }

    /// Whether the picture was made for the whole panel rather than the area below the camera:
    /// its shape is within 1% of the screen's and nearer it than the safe area's. The two
    /// differ by about 3%, and other shapes (16:9, 16:10) fit better below the camera.
    static func coversNotch(video: CGSize,screen: NSRect,topInset: CGFloat) -> Bool {
        guard topInset > 0,video.width > 0,video.height > 0,screen.height > topInset else { return false }
        let shape=video.width/video.height
        let full=abs(log(shape/(screen.width/screen.height)))
        let safe=abs(log(shape/(screen.width/(screen.height-topInset))))
        return full < 0.01 && full < safe
    }

    /// Handles the toggle when it enters or leaves the notch mode; false hands it to AppKit.
    fileprivate func toggle() -> Bool {
        guard let window else { return false }
        if saved != nil { exit();return true }
        guard !window.styleMask.contains(.fullScreen),let screen=window.screen,
              Self.coversNotch(video:videoSize(),screen:screen.frame,topInset:screen.safeAreaInsets.top) else { return false }
        enter(window,screen:screen)
        return true
    }
    private func enter(_ window: NSWindow,screen: NSScreen) {
        Self.adoptKeyableClass(window)
        saved=(window.styleMask,window.frame,NSApp.presentationOptions)
        // Auto-hide rather than hide, so the menu bar still slides down at the top edge as in
        // AppKit's full screen; AppKit requires the Dock option alongside it.
        NSApp.presentationOptions=[.autoHideDock,.autoHideMenuBar]
        window.styleMask=[.borderless]
        window.setFrame(screen.frame,display:true)
        window.makeKeyAndOrderFront(nil)
        let center=NotificationCenter.default
        observers=[
            // A resolution or arrangement change moves the frame; follow it.
            center.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,let window=self.window,let screen=window.screen else { return }
                    window.setFrame(screen.frame,display:true)
                }
            },
            // A stream that ends closes the window; the menu bar must not stay hidden.
            center.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.exit() }
            },
        ]
        center.post(name:Self.didChangeNotification,object:window)
    }
    private func exit() {
        guard let saved else { return }
        self.saved=nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers=[]
        NSApp.presentationOptions=saved.options
        guard let window else { return }
        window.styleMask=saved.style
        window.setFrame(saved.frame,display:true)
        NotificationCenter.default.post(name:Self.didChangeNotification,object:window)
    }

    /// A borderless window cannot become key, so after a switch to another app the stream
    /// would lose the keyboard. SwiftUI owns the window's class, and AppKit asserts if a
    /// window's class is replaced, so the class itself gets the overrides once: windows in
    /// the notch mode answer yes, `toggleFullScreen:` asks the window's controller first,
    /// and every other window runs the class's own methods unchanged.
    private static func adoptKeyableClass(_ window: NSWindow) {
        let cls: AnyClass=type(of:window)
        let name=NSStringFromClass(cls)
        guard !adoptedClasses.contains(name) else { return }
        adoptedClasses.insert(name)
        typealias Getter=@convention(c) (NSWindow,Selector) -> Bool
        for selector in [#selector(getter:NSWindow.canBecomeKey),#selector(getter:NSWindow.canBecomeMain)] {
            let inherited=unsafeBitCast(class_getMethodImplementation(cls,selector),to:Getter.self)
            let block: @convention(block) (NSWindow) -> Bool={ window in
                MainActor.assumeIsolated { isActive(window) } || inherited(window,selector)
            }
            replace(cls,selector,imp_implementationWithBlock(block),"B@:")
        }
        let toggleSelector=#selector(NSWindow.toggleFullScreen(_:))
        typealias Toggle=@convention(c) (NSWindow,Selector,Any?) -> Void
        let inherited=unsafeBitCast(class_getMethodImplementation(cls,toggleSelector),to:Toggle.self)
        let toggle: @convention(block) (NSWindow,Any?) -> Void={ window,sender in
            let handled=MainActor.assumeIsolated { controller(window)?.toggle() == true }
            if !handled { inherited(window,toggleSelector,sender) }
        }
        replace(cls,toggleSelector,imp_implementationWithBlock(toggle),"v@:@")
    }
    /// Adds the method when the class only inherits it, otherwise swaps its implementation.
    private static func replace(_ cls: AnyClass,_ selector: Selector,_ imp: IMP,_ types: String) {
        if !class_addMethod(cls,selector,imp,types),let method=class_getInstanceMethod(cls,selector) {
            method_setImplementation(method,imp)
        }
    }
    private static var adoptedClasses: Set<String>=[]
}
nonisolated(unsafe) private var controllerKey: UInt8=0

extension NSWindow {
    /// In AppKit's full screen or the notch-covering one.
    var isStreamFullScreen: Bool { styleMask.contains(.fullScreen) || NotchFullScreen.isActive(self) }
}
