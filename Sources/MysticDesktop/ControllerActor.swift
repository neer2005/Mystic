import Dispatch

/// Where controllers live, with their buttons and sticks, motion, battery, light and motors, and
/// the captured mouse's movement (`StreamMouse`). Apple's
/// "Handling input events" guide has GameController call input handlers on a device's
/// `handlerQueue`, which is the main queue unless an app gives it its own. On the main queue a
/// press waits behind whatever the main thread is doing: SwiftUI, the stream's stats, the
/// presenter's frame pacing. This actor's queue does nothing but controllers, at user-interactive
/// priority, and every controller's `handlerQueue` is set to it, so GameController calls straight
/// into the actor.
///
/// The main actor reaches in with `run`, which waits for the queue: when input is released the
/// controllers are off before the host is told everything is up, so no press can follow it.
/// Nothing on this queue waits for the main actor, so that wait cannot deadlock.
@globalActor
actor ControllerActor {
    static let shared=ControllerActor()
    static let queue=DispatchSerialQueue(label:"Mystic.Controllers",qos:.userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.queue.asUnownedSerialExecutor() }
    private static let marker=DispatchSpecificKey<Bool>()
    private static let marked: Void={ queue.setSpecific(key:marker,value:true) }()

    /// Runs `body` on the controller queue and returns its result; inline when already there.
    nonisolated static func run<T: Sendable>(_ body: @ControllerActor () throws -> T) rethrows -> T {
        _=marked
        if DispatchQueue.getSpecific(key:marker) == true { return try assumeIsolated(body) }
        return try queue.sync { try assumeIsolated(body) }
    }
    /// `body` on the actor, from code GameController or a timer calls on the controller queue.
    nonisolated static func assumeIsolated<T: Sendable>(_ body: @ControllerActor () throws -> T) rethrows -> T {
        shared.preconditionIsolated()
        // As `MainActor.assumeIsolated`: the check above is what makes the isolation true.
        return try withoutActuallyEscaping(body) { body in
            try unsafeBitCast(body,to:(() throws -> T).self)()
        }
    }
}
