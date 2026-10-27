import AppKit
import MysticStream

@MainActor
final class RemoteVideoView: NSView {
    var presenter: DisplayLayerPresenter
    private weak var capture: StreamInputCapture?
    private var tracking: NSTrackingArea?
    private weak var movementWindow: NSWindow?
    private var previousAcceptsMouseMoved = false
    init(presenter: DisplayLayerPresenter,capture: StreamInputCapture?) {
        self.presenter = presenter;self.capture = capture
        super.init(frame:.zero)
        wantsLayer = true;layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(presenter.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Remote Desktop video")
        setAccessibilityHelp("Click to control the host. Control Option Shift Escape releases input.")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resignFirstResponder() -> Bool { capture?.release();return true }
    override func viewWillMove(toWindow next: NSWindow?) {
        if next !== movementWindow {
            capture?.release()
            movementWindow?.acceptsMouseMovedEvents = previousAcceptsMouseMoved
            movementWindow = next
            if let next { previousAcceptsMouseMoved = next.acceptsMouseMovedEvents;next.acceptsMouseMovedEvents = true }
        }
        super.viewWillMove(toWindow:next)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { capture?.attach(self) } else { capture?.detach(self) }
    }
    func install(_ presenter: DisplayLayerPresenter,capture: StreamInputCapture?) {
        if self.presenter !== presenter {
            self.presenter.layer.removeFromSuperlayer()
            self.presenter = presenter;layer?.addSublayer(presenter.layer);needsLayout = true
        }
        if self.capture !== capture {
            self.capture?.detach(self);self.capture = capture
            if window != nil { capture?.attach(self) }
        }
    }
    func disconnectInput() { capture?.detach(self) }
    override func layout() { super.layout();presenter.layer.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking);self.tracking = tracking
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
