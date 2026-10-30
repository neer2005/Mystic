import Foundation
import CMystic

/// Nightjar's shared reconnect budget. Calls belong to one owner (the app's main actor).
public final class StreamRecovery {
    private let handle: OpaquePointer
    public init() { handle=mystic_recovery_new()! }
    deinit { mystic_recovery_free(handle) }
    public static func recovers(code: Int32, videoStarted: Bool) -> Bool {
        mystic_recovers_termination(code,videoStarted)
    }
    public static func recoversStartup(stage: Stage, code: Int32) -> Bool {
        mystic_recovers_startup(stage.rawValue,code)
    }
    public func nextDelay(nowMillis: UInt64, connectedMillis: UInt64 = 0) -> UInt64? {
        let delay=mystic_recovery_next(handle,nowMillis,connectedMillis)
        return delay < 0 ? nil : UInt64(delay)
    }
    public func remaining(nowMillis: UInt64) -> UInt64 { mystic_recovery_remaining(handle,nowMillis) }
}
