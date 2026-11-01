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
    /// The display's refresh timeline, on the same clock as the frames' ready times.
    public struct Grid: Sendable, Equatable {
        public let anchorMicros: Int64,intervalMicros: Int64,leadMicros: Int64,slackMicros: Int64
        /// A frame is released a quarter refresh before its refresh, and takes the nearest one.
        public init(anchorMicros: Int64,intervalMicros: Int64) {
            self.init(anchorMicros:anchorMicros,intervalMicros:intervalMicros,leadMicros:intervalMicros/4,slackMicros:intervalMicros/2)
        }
        public init(anchorMicros: Int64,intervalMicros: Int64,leadMicros: Int64,slackMicros: Int64) {
            self.anchorMicros=anchorMicros;self.intervalMicros=intervalMicros;self.leadMicros=leadMicros;self.slackMicros=slackMicros
        }
    }
    public struct GridSchedule: Sendable, Equatable {
        /// When to hand the frame over: a lead before its refresh, never before it is ready.
        public let releaseMicros: Int64
        public let refreshMicros: Int64
        public let late: Bool
        /// It has the refresh of the frame before it and replaces it there: content faster than the panel.
        public let sharesRefresh: Bool
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
    /// On a grid the frame already waits for its refresh, and a late one still takes the first it
    /// can make, so covering the worst frames only adds latency to all the others.
    private static let gridPercentile=75
    /// A jump this large between two frames' timestamps is a restarted video clock.
    private static let discontinuityMicros: Int64=10_000_000

    private var lateness: [Int64]=[]
    private var next=0
    private var delay: Int64?
    private var start: Int64?
    private var lastHost: Int64?
    private var lastRefresh: Int64?
    private var lastBumped=false
    private var onGrid=false
    public init() {}
    public var delayMicros: Int64? { delay }
    public mutating func reset() { let grid=onGrid;self=PresentClock();onGrid=grid }

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
            let wanted=quantile(onGrid ? Self.gridPercentile : Self.percentile)+Self.marginMicros
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
    /// Nightjar's `schedule_on_grid`: `schedule`'s time, moved onto a refresh. Never before the first
    /// refresh the frame can make, and at most one past it to keep one frame per refresh, not twice
    /// running, so content faster than the panel does not run behind for good.
    public mutating func schedule(hostMicros host: Int64,readyMicros ready: Int64,grid: Grid) -> GridSchedule {
        onGrid=true
        let base=schedule(hostMicros:host,readyMicros:ready)
        let interval=grid.intervalMicros
        let firstPossible=Self.ceilingDivide(ready-grid.anchorMicros,interval)
        var index=max(firstPossible,Self.ceilingDivide(base.presentMicros-max(grid.slackMicros,0)-grid.anchorMicros,interval))
        var shares=false,bumped=false
        if let lastRefresh {
            // The last frame's refresh as an index on this grid: the anchor moves.
            let taken=Self.floorDivide(lastRefresh-grid.anchorMicros+interval/2,interval)
            if index <= taken {
                if taken == firstPossible && !lastBumped { index=firstPossible+1;bumped=true }
                else { index=taken;shares=true }
            }
        }
        let refresh=grid.anchorMicros+index*interval
        lastRefresh=refresh;lastBumped=bumped
        let release=max(refresh-max(grid.leadMicros,0),ready)
        return GridSchedule(releaseMicros:release,refreshMicros:refresh,late:base.late,sharesRefresh:shares,holdMicros:release-ready)
    }
    private static func floorDivide(_ a: Int64,_ b: Int64) -> Int64 {
        let (quotient,remainder)=a.quotientAndRemainder(dividingBy:b)
        return remainder < 0 ? quotient-1 : quotient
    }
    private static func ceilingDivide(_ a: Int64,_ b: Int64) -> Int64 { floorDivide(a+b-1,b) }
}

/// Where a frame's time went between the decoder finishing it and the system reporting it shown.
public struct PresentationStages: Sendable, Equatable {
    public var toEnqueue: Int64,forDrawable: Int64,encode: Int64,gpu: Int64,toScreen: Int64
    public init(toEnqueue: Int64,forDrawable: Int64,encode: Int64,gpu: Int64,toScreen: Int64) {
        self.toEnqueue=toEnqueue;self.forDrawable=forDrawable;self.encode=encode;self.gpu=gpu;self.toScreen=toScreen
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
