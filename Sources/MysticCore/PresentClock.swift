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
    private var lastPresent: Int64?
    /// The display's shortest refresh interval; presents are never closer.
    public var minIntervalMicros: Int64=0
    public init() {}
    public var delayMicros: Int64? { delay }
    public mutating func reset() { let interval=minIntervalMicros;self=PresentClock();minIntervalMicros=interval }

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
        if let lastPresent { present=max(present,lastPresent+minIntervalMicros) }
        let late=present < ready
        present=min(max(present,ready),ready+Self.maxHoldMicros)
        lastPresent=present
        return Schedule(presentMicros:present,late:late,holdMicros:present-ready)
    }
}

/// Where a frame's time went between the decoder finishing it and the system reporting it shown.
public struct PresentationStages: Sendable, Equatable {
    public var toEnqueue: Int64,forDrawable: Int64,encode: Int64,gpu: Int64,toScreen: Int64
    public init(toEnqueue: Int64,forDrawable: Int64,encode: Int64,gpu: Int64,toScreen: Int64) {
        self.toEnqueue=toEnqueue;self.forDrawable=forDrawable;self.encode=encode;self.gpu=gpu;self.toScreen=toScreen
    }
}

private struct DelayWindow: Sendable, Equatable {
    private var values: [Int64]=[]
    private var next=0
    mutating func add(_ value: Int64) {
        if values.count < 512 { values.append(value) } else { values[next]=value }
        next=(next+1)%512
    }
    var summary: (p50: Int64,p95: Int64)? {
        guard !values.isEmpty else { return nil }
        let sorted=values.sorted()
        return (sorted[(sorted.count-1)/2],sorted[(sorted.count-1)*95/100])
    }
}

/// How far apart frames really reached the screen, from the renderer's own present times.
public struct ShownCadence: Sendable, Equatable {
    private var intervals: [Int64]=[]
    private var next=0
    private var last: Int64?
    private var delays: [Int64]=[]
    private var nextDelay=0
    private var stages: [PresentationStages]=[]
    private var pcToReceived=DelayWindow(),pcToShown=DelayWindow()
    private var nextStages=0
    public private(set) var shown: UInt64=0
    public init() {}
    /// `readyToShownMicros`: from the decoder finishing the frame to the screen, when known.
    public mutating func record(presentedMicros: Int64,readyToShownMicros: Int64? = nil) {
        shown &+= 1
        if let readyToShownMicros {
            if delays.count < 512 { delays.append(readyToShownMicros) } else { delays[nextDelay]=readyToShownMicros }
            nextDelay=(nextDelay+1)%512
        }
        if let last,presentedMicros > last {
            let interval=presentedMicros-last
            if intervals.count < 512 { intervals.append(interval) } else { intervals[next]=interval }
            next=(next+1)%512
        }
        last=presentedMicros
    }
    /// Median and 95th and 99th percentile of the recent intervals.
    public var summary: (p50: Int64,p95: Int64,p99: Int64)? {
        guard !intervals.isEmpty else { return nil }
        let sorted=intervals.sorted()
        func at(_ percent: Int) -> Int64 { sorted[(sorted.count-1)*percent/100] }
        return (at(50),at(95),at(99))
    }
    public mutating func record(stages value: PresentationStages) {
        if stages.count < 512 { stages.append(value) } else { stages[nextStages]=value }
        nextStages=(nextStages+1)%512
    }
    /// From the PC presenting a frame to it arriving here and to it being shown, by clock sync.
    public mutating func record(pcToReceivedMicros received: Int64,pcToShownMicros shown: Int64) {
        pcToReceived.add(received);pcToShown.add(shown)
    }
    public var pcToReceivedSummary: (p50: Int64,p95: Int64)? { pcToReceived.summary }
    public var pcToShownSummary: (p50: Int64,p95: Int64)? { pcToShown.summary }
    /// Each stage's median and 95th percentile, by name, in order.
    public var stageSummary: [(name: String,p50: Int64,p95: Int64)] {
        guard !stages.isEmpty else { return [] }
        let columns: [(String,KeyPath<PresentationStages,Int64>)]=[("to enqueue",\.toEnqueue),("for drawable",\.forDrawable),("encode",\.encode),("GPU",\.gpu),("to screen",\.toScreen)]
        return columns.map { name,path in
            let sorted=stages.map { $0[keyPath:path] }.sorted()
            return (name,sorted[(sorted.count-1)/2],sorted[(sorted.count-1)*95/100])
        }
    }
    /// Median and 95th percentile of recent decoded-to-screen times: what a pacing costs in delay.
    public var readyToShown: (p50: Int64,p95: Int64)? {
        guard !delays.isEmpty else { return nil }
        let sorted=delays.sorted()
        return (sorted[(sorted.count-1)/2],sorted[(sorted.count-1)*95/100])
    }
    /// The share of intervals away from the median by over a quarter of it: uneven frames.
    public var unevenShare: Double? {
        guard let median=summary?.p50,median > 0 else { return nil }
        return Double(intervals.filter { abs($0-median) > median/4 }.count)/Double(intervals.count)
    }
}
