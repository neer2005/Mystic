import AppKit
import MysticStream

@MainActor
final class RemoteVideoView: NSView {
    var presenter: DisplayLayerPresenter
    private weak var capture: StreamInputCapture?
    private var tracking: NSTrackingArea?
    private weak var movementWindow: NSWindow?
    private var previousAcceptsMouseMoved = false
    private var displayObservers: [any NSObjectProtocol] = []
    private var headroomTimer: Timer?
    init(presenter: DisplayLayerPresenter,capture: StreamInputCapture?) {
        self.presenter = presenter;self.capture = capture
        super.init(frame:.zero)
        wantsLayer = true;layer?.backgroundColor = NSColor.black.cgColor;layer?.masksToBounds = true
        layer?.addSublayer(presenter.surface)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Remote Desktop video")
        setAccessibilityHelp("Click to control the host. Control Option Shift Escape releases input.")
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { stopObservingDisplay() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resignFirstResponder() -> Bool {
        if !NotchFullScreen.isRestyling(window) { capture?.release() }
        return true
    }
    /// A window changing to or from the notch-covering full screen takes this view out and puts
    /// it back (see `NotchFullScreen.isRestyling`); input stays with the host across that.
    private var restyling: Bool { NotchFullScreen.isRestyling(movementWindow) }
    override func viewWillMove(toWindow next: NSWindow?) {
        if next !== movementWindow,!(next == nil && restyling) {
            capture?.release()
            movementWindow?.acceptsMouseMovedEvents = previousAcceptsMouseMoved
            movementWindow = next
            if let next { previousAcceptsMouseMoved = next.acceptsMouseMovedEvents;next.acceptsMouseMovedEvents = true }
        }
        super.viewWillMove(toWindow:next)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil,restyling { return }
        stopObservingDisplay()
        if let window {
            let center=NotificationCenter.default
            for (name,object) in [(NSWindow.didChangeScreenNotification,window as AnyObject?),
                                  (NSApplication.didChangeScreenParametersNotification,nil)] {
                displayObservers.append(center.addObserver(forName:name,object:object,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateDisplay() }
                })
            }
        }
        updateDisplay()
        if window != nil { watchHeadroom() }
        if window != nil { capture?.attach(self) } else { capture?.detach(self) }
    }
    private func updateDisplay() {
        let screen=window?.screen
        needsLayout = true
        if let screen { presenter.setRefresh(hertz:DisplayRefresh.hertz(screen)) }
        presenter.updateDisplay(name:screen?.localizedName,
            currentHeadroom:screen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) },
            potentialHeadroom:screen.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) })
    }
    private func stopObservingDisplay() {
        for observer in displayObservers { NotificationCenter.default.removeObserver(observer) }
        displayObservers.removeAll()
        headroomTimer?.invalidate();headroomTimer=nil
    }
    /// macOS sends no notice when a screen's EDR headroom moves (brightness, ambient light, HDR
    /// coming on screen), and the Metal renderer tone maps HDR to it, so it is read four times a
    /// second; only a change reaches the presenter.
    private func watchHeadroom() {
        headroomTimer?.invalidate()
        headroomTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,let screen=self.window?.screen else { return }
                let current=Double(screen.maximumExtendedDynamicRangeColorComponentValue)
                if current != self.presenter.videoOutput.currentHeadroom { self.presenter.updateHeadroom(current) }
            }
        }
    }
    func install(_ presenter: DisplayLayerPresenter,capture: StreamInputCapture?) {
        if self.presenter !== presenter {
            self.presenter.updateDisplay(name:nil,currentHeadroom:nil,potentialHeadroom:nil)
            self.presenter.surface.removeFromSuperlayer()
            self.presenter = presenter;layer?.addSublayer(presenter.surface);needsLayout = true
            updateDisplay()
        }
        if self.capture !== capture {
            self.capture?.detach(self);self.capture = capture
            if window != nil { capture?.attach(self) }
        }
    }
    func disconnectInput() { capture?.detach(self);stopObservingDisplay();presenter.updateDisplay(name:nil,currentHeadroom:nil,potentialHeadroom:nil) }
    override func layout() { super.layout();presenter.layout(in:bounds,pixelsPerPoint:window?.backingScaleFactor ?? 1) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking);self.tracking = tracking
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let capture,capture.drawsHostCursor { addCursorRect(presenter.videoRect.intersection(bounds),cursor:capture.hostCursor.current) }
    }
    func isVideoPoint(_ point: NSPoint) -> Bool { presenter.videoRect.contains(convert(point,from:nil)) }
    override func mouseDown(with event: NSEvent) { capture?.mouseButton(event,down:true) }
    override func mouseUp(with event: NSEvent) { capture?.mouseButton(event,down:false) }
    override func rightMouseDown(with event: NSEvent) { capture?.mouseButton(event,down:true) }
    override func rightMouseUp(with event: NSEvent) { capture?.mouseButton(event,down:false) }
    override func otherMouseDown(with event: NSEvent) { capture?.mouseButton(event,down:true) }
    override func otherMouseUp(with event: NSEvent) { capture?.mouseButton(event,down:false) }
    override func mouseMoved(with event: NSEvent) { capture?.mouseMotion(event) }
    override func mouseDragged(with event: NSEvent) { capture?.mouseMotion(event,dragged:true) }
    override func rightMouseDragged(with event: NSEvent) { capture?.mouseMotion(event,dragged:true) }
    override func otherMouseDragged(with event: NSEvent) { capture?.mouseMotion(event,dragged:true) }
    override func scrollWheel(with event: NSEvent) { capture?.scroll(event) }
    override func keyDown(with event: NSEvent) { if capture?.handleKey(event) != true { super.keyDown(with:event) } }
    override func keyUp(with event: NSEvent) { if capture?.handleKey(event) != true { super.keyUp(with:event) } }
    override func flagsChanged(with event: NSEvent) { _ = capture?.handleKey(event) }
}

/// Text from the emoji picker, the Character Viewer and dictation arrives as inserted text; it
/// goes to the host's focused text field. Keys never go through the text system (they go to
/// the host as keys), so nothing is ever composed or marked here.
extension RemoteVideoView: @MainActor NSTextInputClient {
    func insertText(_ string: Any,replacementRange: NSRange) {
        let text=(string as? NSAttributedString)?.string ?? string as? String ?? ""
        capture?.insert(text)
    }
    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any,selectedRange: NSRange,replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location:NSNotFound,length:0) }
    func markedRange() -> NSRange { NSRange(location:NSNotFound,length:0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange,actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange,actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds,to:nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
