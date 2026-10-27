/// Platform-independent reference recovery and timestamp handling.
public struct VideoRecovery: Sendable {
    public private(set) var needsKeyFrame = true
    public init() {}
    public mutating func invalidate() { needsKeyFrame = true }
    public mutating func accept(isKeyFrame: Bool, hasConfiguration: Bool) -> Bool {
        guard hasConfiguration, !needsKeyFrame || isKeyFrame else { return false }
        needsKeyFrame = false
        return true
    }
}

public enum VideoTimestamp {
    /// Integer arithmetic preserves microseconds and rejects unrepresentable timestamps.
    public static func relativeMicros(_ timestamp: UInt64, origin: UInt64) -> Int64? {
        guard timestamp >= origin, timestamp - origin <= UInt64(Int64.max) else { return nil }
        return Int64(timestamp - origin)
    }
}
