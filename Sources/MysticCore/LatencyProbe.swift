import Foundation

/// Measures input to screen on a still host screen: the host only sends a frame when the picture
/// changes, so the first frame received after a small mouse nudge is the host's answer to it.
/// Nightjar's `LatencyProbe`, in microseconds of the clock frames' receive times are on.
public final class LatencyProbe: @unchecked Sendable {
    /// A frame within this long before the nudge means the screen is still changing by itself.
    public static let idleMicros: Int64=150_000
    public struct Summary: Sendable, Equatable {
        public let bestMicros: Int64,typicalMicros: Int64,slowestMicros: Int64
    }
    private let lock=NSLock()
    private var lastReceive: Int64=0
    private var sent: Int64=0
    private var result: Int64?
    public init() {}
    public var armed: Bool { lock.lock();defer { lock.unlock() };return sent != 0 }
    public func frameReceived(_ receive: Int64) {
        lock.lock();defer { lock.unlock() }
        lastReceive=max(lastReceive,receive)
    }
    public func frameRendered(receive: Int64,render: Int64) {
        lock.lock();defer { lock.unlock() }
        if sent != 0,result == nil,receive >= sent,render >= receive { result=render-sent }
    }
    /// Whether no frame has arrived for `idleMicros`.
    public func isIdle(now: Int64) -> Bool {
        lock.lock();defer { lock.unlock() }
        return now-lastReceive >= Self.idleMicros
    }
    /// Call right before sending the nudge.
    public func arm(now: Int64) {
        lock.lock();defer { lock.unlock() }
        sent=now;result=nil
    }
    /// The armed nudge's input-to-screen time, once its frame has shown.
    public var answer: Int64? { lock.lock();defer { lock.unlock() };return result }
    public func disarm() {
        lock.lock();defer { lock.unlock() }
        sent=0;result=nil
    }
    /// Best, median and 90th percentile; nil without samples.
    public static func summarize(_ samples: [Int64]) -> Summary? {
        guard !samples.isEmpty else { return nil }
        let sorted=samples.sorted(),count=sorted.count
        return Summary(bestMicros:sorted[0],typicalMicros:sorted[count/2],
                       slowestMicros:sorted[min(count-1,Int((Double(count)*0.9).rounded(.up))-1)])
    }
}
