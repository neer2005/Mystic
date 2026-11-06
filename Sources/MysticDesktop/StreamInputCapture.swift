import AppKit
import CoreGraphics
import Observation
import MysticCore

/// Local-window input only. No global event tap, Accessibility access, or Input Monitoring grant.
@MainActor @Observable
public final class StreamInputCapture {
    public enum Mode: String { case released, desktop, relative }
    public private(set) var mode: Mode = .released
    public private(set) var available = false
    /// A controller moves the PC's pointer (Nightjar's controller mouse mode).
    public private(set) var controllerMouse = false
    /// A controller's leave combo was pressed.
    @ObservationIgnored var leaveStream: (() -> Void)?
    public var status: String {
        if controllerMouse,mode != .released { return "Controller mouse • A/B click, D-pad scrolls • hold Start for the controller" }
        return switch mode {
        case .released: available ? "Click video to control • ⌃⌥⇧Esc releases input" : "Input waiting for connection"
        case .desktop: "Desktop control • ⌃⌥⇧Esc releases input"
        case .relative: "Mouse captured • ⌃⌥⇧Esc releases input"
        }
    }
    /// Also called on the controller queue (`ControllerActor`), so it must be safe from any thread.
    @ObservationIgnored private let send: @Sendable (RemoteInputEvent) -> Bool
    @ObservationIgnored private let failure: (String) -> Void
    @ObservationIgnored private weak var view: RemoteVideoView?
    @ObservationIgnored private var controllers: StreamControllers?
    /// The captured mouse's movement through GameController, off the main thread.
    @ObservationIgnored private var mouse: StreamMouse?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var state = RemoteInputState()
    @ObservationIgnored private var movement = InputDelta()
    @ObservationIgnored private var wheel = InputDelta()
    @ObservationIgnored private var pointerDetached = false
    @ObservationIgnored private var cursorHidden = false
    @ObservationIgnored private var restorePoint: CGPoint?
    @ObservationIgnored private var skipWarpMotion = false
    /// Applies at once, during a stream too.
    @ObservationIgnored var input=InputPreferences() {
        didSet {
            guard input != oldValue else { return }
            if let mouse,mode == .relative {
                let scale=input.mouseScale
                ControllerActor.run { mouse.setEnabled(true,scale:scale) }
            }
            guard let controllers else { return }
            let input=input,changed=input.controllers != oldValue.controllers,active=input.controllers && mode != .released
            ControllerActor.run {
                controllers.settings=input
                if changed { controllers.setActive(active) }
            }
        }
    }
    /// The host's cursor as the pointer over the video while it sends shapes.
    @ObservationIgnored let hostCursor = HostCursor()
    @ObservationIgnored private(set) var hostCursorOn = false
    @ObservationIgnored private var hostCursorWarned = false
    /// Text that came without a key (the emoji picker, dictation) while the stream runs.
    @ObservationIgnored var insertText: ((String) -> Void)?
    /// Takes inserted text: only printable text, and only while a stream accepts input. Keys
    /// never reach the text system, so nothing here echoes a key already sent.
    func insert(_ text: String) {
        guard available,!text.isEmpty,!text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
        insertText?(text)
    }
    /// Desktop control draws the host's cursor; the host has left it out of the video.
    var drawsHostCursor: Bool { hostCursorOn && mode == .desktop }

    init(send: @escaping @Sendable (RemoteInputEvent) -> Bool, failure: @escaping (String) -> Void) {
        self.send = send;self.failure = failure
        hostCursor.changed = { [weak self] in self?.refreshCursor() }
        hostCursor.failure = { [weak self] message in
            guard let self,!self.hostCursorWarned else { return }
            self.hostCursorWarned = true;self.failure(message)
        }
    }
    isolated deinit { release() }
    func attach(_ target: RemoteVideoView) {
        if view === target { return }
        release();view = target
    }
    func detach(_ target: RemoteVideoView) {
        guard view === target else { return };release();view = nil
    }
    func setAvailable(_ enabled: Bool) { if !enabled { release() };available = enabled }
    public func controlDesktop() { activate(.desktop) }
    public func captureMouse() { activate(.relative) }
    private func activate(_ next: Mode) {
        guard available, let view, let window = view.window else { return }
        release()
        guard !view.presenter.videoRect.isEmpty else { failure("Wait for the first video frame before controlling the host.");return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        guard window.makeFirstResponder(view) else { failure("The video view could not receive keyboard focus.");return }
        state = RemoteInputState(capsLock:NSEvent.modifierFlags.contains(.capsLock))
        movement = InputDelta();wheel = InputDelta()
        if next == .relative {
            let rect = view.presenter.videoRect
            guard !rect.isEmpty else { failure("Wait for the first video frame before capturing the mouse.");return }
            restorePoint = Self.cgPoint(NSEvent.mouseLocation)
            let center = window.convertPoint(toScreen:view.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil))
            guard CGWarpMouseCursorPosition(Self.cgPoint(center)) == .success,
                  CGAssociateMouseAndMouseCursorPosition(0) == .success else {
                _ = CGAssociateMouseAndMouseCursorPosition(1)
                if let restorePoint { _ = CGWarpMouseCursorPosition(restorePoint) }
                restorePoint = nil;failure("Mouse capture is unavailable. Desktop pointer control still works.");return
            }
            pointerDetached = true;skipWarpMotion = true
            NSCursor.hide();cursorHidden = true
        }
        mode = next
        refreshCursor()
        if next == .relative {
            if mouse == nil { mouse=makeMouse() }
            if let mouse {
                let scale=input.mouseScale
                ControllerActor.run { mouse.setEnabled(true,scale:scale) }
            }
        }
        if controllers == nil { controllers=makeControllers() }
        if let controllers {
            let enabled=input.controllers
            ControllerActor.run { controllers.setEnabled(enabled) }
        }
        guard mode != .released else { return }
        installMonitor(window:window)
    }
    var clipboardActive: Bool { available && NSApp.isActive && view?.window?.isKeyWindow == true }
    private func makeMouse() -> StreamMouse {
        let send=send
        return ControllerActor.run {
            StreamMouse(send:send,failure: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.release();self?.failure("Input backlog was full. Control released to avoid stuck keys; click the video to resume.")
                    }
                }
            })
        }
    }
    /// Controllers report on their own queue; what they say to the user comes back here, in order.
    private func makeControllers() -> StreamControllers {
        let send=send,input=input
        let toMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void={ work in
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
        return ControllerActor.run {
            let controllers=StreamControllers(feedbackFailure: { [weak self] message in toMain { self?.failure(message) } },send:send,failure: { [weak self] in
                toMain { self?.release();self?.failure("Controller input backlog was full. Control released; click video to resume.") }
            })
            controllers.settings=input
            controllers.leave = { [weak self] in toMain { self?.leaveStream?() } }
            // Mystic's stand-in for Nightjar's stream menu: as ⌃⌥⇧Esc, so the window's controls are in reach.
            controllers.guideHeld = { [weak self] in
                toMain {
                    guard let self else { return }
                    self.failure("Guide held: input released to the Mac. Click the video to control the PC again.")
                    self.release()
                }
            }
            controllers.mouseSwitched = { [weak self] on in
                toMain {
                    guard let self else { return }
                    self.controllerMouse=on
                    // Nightjar's toasts, in the session log.
                    self.failure(on ? "Controller mouse enabled. A/B click; D-pad scrolls. Hold Start to return to gamepad." : "Controller mouse disabled.")
                }
            }
            return controllers
        }
    }
    var feedbackEpoch: UInt64? {
        guard mode != .released,let controllers else { return nil }
        return ControllerActor.run { controllers.feedbackEpoch }
    }
    func applyControllerFeedback(_ values: [ControllerFeedback],epoch: UInt64?) {
        guard mode != .released,let epoch,let controllers else { return }
        ControllerActor.run { controllers.applyFeedback(values,epoch:epoch) }
    }
    public func release() {
        let hadInput = mode != .released
        mode = .released
        // Waits for the controller queue, so no press reaches the host after the release below.
        if let controllers { ControllerActor.run { controllers.setEnabled(false) } }
        if let mouse { ControllerActor.run { mouse.setEnabled(false,scale:1) } }
        if let monitor { NSEvent.removeMonitor(monitor);self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if pointerDetached { _ = CGAssociateMouseAndMouseCursorPosition(1);pointerDetached = false }
        if cursorHidden { NSCursor.unhide();cursorHidden = false }
        if let restorePoint { _ = CGWarpMouseCursorPosition(restorePoint);self.restorePoint = nil }
        if hadInput { _ = send(state.releaseAll()) }
        movement = InputDelta();wheel = InputDelta()
        refreshCursor()
    }
    /// Shapes were turned on or off at the host; either way it starts its image cache again.
    func setHostCursor(_ on: Bool) {
        hostCursorOn = on;hostCursor.reset();refreshCursor()
    }
    func applyHostCursor(_ shapes: [HostCursorShape]) { if hostCursorOn { hostCursor.apply(shapes) } }
    private func refreshCursor() {
        guard let view,let window = view.window else { return }
        window.invalidateCursorRects(for:view)
        // Cursor rects apply on the next movement; a pointer already over the video changes now.
        if window.isKeyWindow,view.isVideoPoint(window.mouseLocationOutsideOfEventStream),mode != .relative {
            (drawsHostCursor ? hostCursor.current : NSCursor.arrow).set()
        }
    }
    private static func cgPoint(_ cocoa: NSPoint) -> CGPoint {
        CGPoint(x:cocoa.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-cocoa.y)
    }
    private func installMonitor(window: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.mode != .released else { return false }
                if [.keyDown,.keyUp,.flagsChanged].contains(event.type) { return self.handleKey(event) }
                if self.mode == .desktop, let view = self.view,
                   event.window !== view.window || !view.isVideoPoint(event.locationInWindow) { self.release() }
                return false
            }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification,NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.release() }
            })
        }
        observers.append(center.addObserver(forName:NSApplication.willResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release() }
        })
    }
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard mode != .released, let view,
              event.window == nil || event.window === view.window,
              view.window?.isKeyWindow == true, view.window?.firstResponder === view else { return false }
        let releaseFlags: NSEvent.ModifierFlags = [.control,.option,.shift]
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.intersection(releaseFlags) == releaseFlags {
            release();return true
        }
        let events: [RemoteInputEvent]
        if MacKeyboard.modifierDeviceMask(event.keyCode) != nil {
            // Accessibility/synthetic input can deliver a modifier as keyDown/keyUp rather than flagsChanged.
            events = state.modifier(event.keyCode,rawFlags:UInt64(event.modifierFlags.rawValue),capsLock:event.modifierFlags.contains(.capsLock))
            emit(events);return true
        }
        switch event.type {
        case .keyDown:
            events = state.synchronizeModifiers(rawFlags:UInt64(event.modifierFlags.rawValue)) + state.key(event.keyCode,down:true,repeatEvent:event.isARepeat)
        case .keyUp:
            events = state.synchronizeModifiers(rawFlags:UInt64(event.modifierFlags.rawValue)) + state.key(event.keyCode,down:false)
        case .flagsChanged: events = state.modifier(event.keyCode,rawFlags:UInt64(event.modifierFlags.rawValue),capsLock:event.modifierFlags.contains(.capsLock))
        default:return false
        }
        emit(events)
        // While controlling the host, AppKit menu shortcuts and unknown/media keys stay out of the host.
        return true
    }
    func mouseButton(_ event: NSEvent, down: Bool) {
        guard let view else { return }
        if mode == .released {
            // The activation click does not perform an unexpected action on the remote desktop.
            if down, view.isVideoPoint(event.locationInWindow) { controlDesktop() }
            return
        }
        if event.buttonNumber >= 3,!input.mouseNavigationButtons { return }
        if mode == .desktop { position(event,clamp:!down) }
        emit(state.button(event.buttonNumber,down:down))
    }
    func mouseMotion(_ event: NSEvent, dragged: Bool = false) {
        guard mode != .released else { return }
        if mode == .desktop { position(event,clamp:dragged) }
        else {
            if skipWarpMotion { skipWarpMotion = false;return }
            // GameController sent this movement already, unaccelerated and off the main thread.
            if mouse?.activity.covers == true { return }
            let (dx,dy) = movement.consume(x:event.deltaX,y:event.deltaY,scale:input.mouseScale)
            if dx != 0 || dy != 0 { emit([.motion(dx:dx,dy:dy)]) }
        }
    }
    func scroll(_ event: NSEvent) {
        guard mode != .released else { return }
        let scale: Double = event.hasPreciseScrollingDeltas ? 12 : 120
        // Cocoa horizontal scrolling uses the opposite sign to host wheel-right.
        let (horizontal,vertical) = wheel.consume(x:-event.scrollingDeltaX,y:event.scrollingDeltaY,scale:scale)
        if horizontal != 0 || vertical != 0 { emit([.scroll(vertical:vertical,horizontal:horizontal)]) }
    }
    private func position(_ event: NSEvent,clamp: Bool) {
        guard let view else { return }
        let p = view.convert(event.locationInWindow,from:nil),r = view.presenter.videoRect
        if let position = InputGeometry.position(x:p.x,y:p.y,left:r.minX,bottom:r.minY,width:r.width,height:r.height,clamp:clamp) { emit([position]) }
    }
    private func emit(_ events: [RemoteInputEvent]) {
        for event in events {
            guard send(event) else {
                release();failure("Input backlog was full. Control released to avoid stuck keys; click the video to resume.");break
            }
        }
    }
}
