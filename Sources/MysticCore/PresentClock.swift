/// Shows each frame at its time on the PC plus a steady delay, so the screen follows the game's
/// cadence rather than the network's. Nightjar's `present_clock.rs` `schedule`, in microseconds.
/// The delay is a high percentile of how late frames were recently ready, against their own
/// timestamps, so any offset between the two clocks cancels and slow drift is followed.
public struct PresentClock: Sendable {
    public struct Schedule: Sendable, Equatable {
        public let presentMicros: Int64
        public let late: Bool
        public let holdMicros: Int64
    }
    /// Frames whose lateness sets the delay.
    private static let window=128
    /// Share of frames, in percent, that should be ready before their present time.
    private static let percentile=97
    /// Added to the delay for the present call itself.
    private static let marginMicros: Int64=500
    /// The least the delay falls per frame when it is above the percentile.
    private static let decayMicros: Int64=25
    /// The longest a frame is held after it is ready.
    private static let maxHoldMicros: Int64=50_000
    /// The first pictures come in a burst while the decoder warms up: shown when ready, not learned.
    private static let warmupMicros: Int64=250_000
    /// The gap between the delay and the percentile shrinks by `dt / tau` for each `dt` of PC time.
    private static let fallTauMicros: Int64=500_000
    private static let fallStepMaxMicros: Int64=100_000
    /// A jump this large between two frames' timestamps is a restarted video clock.
    private static let discontinuityMicros: Int64=10_000_000

    private var lateness: [Int64]=[]
    private var next=0
    private var delay: Int64?
    private var start: Int64?
    private var lastHost: Int64?
    public init() {}
    public var delayMicros: Int64? { delay }
    public mutating func reset() { self=PresentClock() }

    private func quantile(_ percent: Int) -> Int64 {
        lateness.sorted()[(lateness.count-1)*percent/100]
    }
    /// When to show the frame stamped `hostMicros`, ready at `readyMicros`. Call once per frame, in
    /// order: each call teaches the clock that frame's lateness.
    public mutating func schedule(hostMicros host: Int64,readyMicros ready: Int64) -> Schedule {
        if let lastHost,abs(host-lastHost) > Self.discontinuityMicros { reset() }
        let first=start ?? host
        start=first
        let step=lastHost.map { host-$0 } ?? 0
        lastHost=host
        var present: Int64
        if host-first < Self.warmupMicros {
            present=ready+Self.marginMicros
        } else {
            if lateness.count < Self.window { lateness.append(ready-host) } else { lateness[next]=ready-host }
            next=(next+1)%Self.window
            let wanted=quantile(Self.percentile)+Self.marginMicros
            var value=wanted
            if let held=delay,wanted < held {
                let fall=(held-wanted)*min(max(step,0),Self.fallStepMaxMicros)/Self.fallTauMicros
                value=max(held-max(fall,Self.decayMicros),wanted)
            }
            // However late frames were, one is held at most this far beyond the typical frame.
            value=min(value,quantile(50)+Self.maxHoldMicros)
            delay=value
            present=host+value
        }
        let late=present < ready
        present=min(max(present,ready),ready+Self.maxHoldMicros)
        return Schedule(presentMicros:present,late:late,holdMicros:present-ready)
    }
}
