import Foundation
import GameController
import MysticCore

/// The captured mouse's movement through GameController. Each `GCMouse` calls its handlers on
/// `ControllerActor`'s queue, so motion reaches the host without waiting for the main thread, and
/// it comes as the mouse's own counts, without macOS's pointer acceleration: the host's own mouse
/// settings are the only curve, as when the mouse is plugged into the PC.
///
/// Only motion: clicks and scrolling stay with AppKit, which also sees tap-to-click and trackpad
/// scrolling, and desktop control needs AppKit's absolute positions. Not every pointing device is
/// a `GCMouse`, a trackpad among them on some Macs, so AppKit's motion still flows unless a
/// `GCMouse` has just reported (`MouseMotionActivity`).
@ControllerActor
final class StreamMouse {
    nonisolated let activity=MouseMotionActivity()
    private let send: @Sendable (RemoteInputEvent) -> Bool
    private let failure: @Sendable () -> Void
    private var movement=InputDelta()
    private var scale=1.0
    private var enabled=false
    private var mice: [GCMouse]=[]
    private var observers: [NSObjectProtocol]=[]
    private let connectedMice: () -> [GCMouse]
    init(connectedMice: @escaping () -> [GCMouse] = { GCMouse.mice() },
         send: @escaping @Sendable (RemoteInputEvent) -> Bool,failure: @escaping @Sendable () -> Void) {
        self.connectedMice=connectedMice;self.send=send;self.failure=failure
        let center=NotificationCenter.default,queue=OperationQueue()
        queue.underlyingQueue=ControllerActor.queue;queue.maxConcurrentOperationCount=1
        for name in [NSNotification.Name.GCMouseDidConnect,NSNotification.Name.GCMouseDidDisconnect] {
            observers.append(center.addObserver(forName:name,object:nil,queue:queue) { [weak self] _ in
                ControllerActor.assumeIsolated { self?.attach() }
            })
        }
    }
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        detach()
    }
    /// On while the mouse is captured; `scale` is the mouse speed setting.
    func setEnabled(_ value: Bool,scale: Double) {
        self.scale=scale
        guard value != enabled else { return }
        enabled=value;movement=InputDelta();activity.clear()
        if value { attach() } else { detach() }
    }
    private func attach() {
        detach()
        guard enabled else { return }
        mice=connectedMice()
        for mouse in mice {
            mouse.handlerQueue=ControllerActor.queue
            mouse.mouseInput?.mouseMovedHandler = { [weak self] _,dx,dy in
                ControllerActor.assumeIsolated { self?.moved(dx:dx,dy:dy) }
            }
        }
    }
    private func detach() {
        for mouse in mice { mouse.mouseInput?.mouseMovedHandler=nil }
        mice.removeAll()
    }
    /// GameController's y runs up; the host's, like AppKit's deltas, runs down.
    func moved(dx: Float,dy: Float) {
        guard enabled else { return }
        activity.mark()
        let (x,y)=movement.consume(x:Double(dx),y:-Double(dy),scale:scale)
        guard x != 0 || y != 0 else { return }
        if !send(.motion(dx:x,dy:y)) { setEnabled(false,scale:scale);failure() }
    }
}

/// When a `GCMouse` last moved, read by AppKit's handlers on the main thread. Within
/// `window` of it, AppKit's motion is the same movement again and is dropped; after it, the
/// motion is from a device GameController does not see, and goes to the host.
final class MouseMotionActivity: @unchecked Sendable {
    static let window: UInt64=100_000_000
    private let lock=NSLock()
    private var last: UInt64?
    private let now: @Sendable () -> UInt64
    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.now=now }
    func mark() { let time=now();lock.withLock { last=time } }
    func clear() { lock.withLock { last=nil } }
    /// A `GCMouse` is reporting this movement already.
    var covers: Bool {
        let time=now()
        return lock.withLock { last.map { time >= $0 && time-$0 < Self.window } ?? false }
    }
}
