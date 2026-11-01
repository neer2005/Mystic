/// Presentation policy only: source PTS and the renderer clock have independent origins.
public enum FramePacingMode: String, CaseIterable, Codable, Hashable, Sendable {
    case lowLatency = "lowLatency"
    case balanced = "balanced"
    case fpsLimit = "fpsLimit"
    case smoothest = "smoothest"
    case pcFrameTimes = "pcFrameTimes"
    public var label: String {
        switch self {
        case .lowLatency: "Low Latency"
        case .balanced: "Balanced"
        case .fpsLimit: "Balanced with FPS Limit"
        case .smoothest: "Smoothest Video"
        case .pcFrameTimes: "PC Frame Times"
        }
    }
    public var detail: String {
        switch self {
        case .lowLatency: "Presents decoded frames without intentional buffering."
        case .balanced: "Uses about one frame of buffering to absorb arrival jitter."
        case .fpsLimit: "Shows no more frames a second than the stream's rate: an early frame waits up to one frame for its turn."
        case .smoothest: "Shows every frame in turn at the PC's timing, with about two frames of buffering. Adds the most delay."
        case .pcFrameTimes: "Shows each frame at its time on the PC, behind a delay that follows recent network and decoder jitter."
        }
    }
    /// The in-order pacings: a newer frame does not replace an older one that is still fresh.
    public var keepsOrder: Bool { self != .lowLatency && self != .balanced }
    /// Decoded frames the presenter may hold, besides the one it is working on.
    public var retainedFrames: Int { keepsOrder ? 3 : 1 }
}

public enum PresentationDropReason: String, CaseIterable, Hashable, Sendable {
    case superseded, late, outOfOrder, invalidTimestamp, reset, enqueueFailure
}

public struct FramePacingPlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case enqueue(timeMicros: Int64, late: Bool, resynchronize: Bool)
        case wait(microseconds: UInt64)
        case drop(PresentationDropReason)
        case recoverTimestamp
    }
    public let action: Action
}

/// No clock or I/O: the presenter supplies renderer-relative time and local image age.
/// A plan does not commit source ordering until the renderer accepts that image.
public struct FramePacer: Sendable {
    public let mode: FramePacingMode
    public private(set) var frameRate: UInt32 = 60
    public var hasAcceptedFrame: Bool { lastSourcePTS != nil }
    public var frameIntervalMicros: Int64 { (1_000_000 + Int64(frameRate)/2)/Int64(frameRate) }
    private var anchorSource: Int64?
    private var anchorRenderer: Int64 = 0
    private var lastSourcePTS: Int64?
    private var lastAcceptedAt: Int64?
    private var lastSlot: Int64?
    private var plannedSlot: Int64?
    private var clock=PresentClock()
    /// The display's refresh timeline on the renderer clock, for `pcFrameTimes`; none without one.
    public var refreshGrid: PresentClock.Grid?
    /// The latest planned frame takes the refresh of the one before it.
    public private(set) var sharesRefresh=false
    /// How long `pcFrameTimes` is holding the latest planned frame after it was ready.
    public private(set) var holdMicros: Int64?
    private var pendingResynchronization = false
    private var futureStrikes = 0
    private var earlyOrLateStrikes = 0
    private var anchorBuffer: Int64 = 0
    private var sourceSteps: [Int64] = []
    private var nextStep = 0
    private var lastSeenSource: Int64?
    public init(mode: FramePacingMode = .lowLatency) { self.mode=mode }
    public mutating func reset() { let grid=refreshGrid;self=FramePacer(mode:mode);refreshGrid=grid }

    public mutating func plan(sourcePTS: Int64, rendererNow: Int64, ageMicros: UInt64?, frameRate: UInt32) -> FramePacingPlan {
        func result(_ action: FramePacingPlan.Action) -> FramePacingPlan { FramePacingPlan(action:action) }
        guard sourcePTS >= 0,rendererNow >= 0,(1...1000).contains(frameRate) else { return result(.drop(.invalidTimestamp)) }
        if let lastSourcePTS,sourcePTS <= lastSourcePTS { return result(.drop(.outOfOrder)) }
        if let lastSourcePTS,let lastAcceptedAt {
            let elapsed=rendererNow >= lastAcceptedAt ? rendererNow-lastAcceptedAt : 0
            let step=sourcePTS-lastSourcePTS
            if step > elapsed,step-elapsed > 100_000 { return futureTimestamp() }
        }
        let interval=(1_000_000 + Int64(frameRate)/2)/Int64(frameRate)
        let ageLimit=mode == .lowLatency ? interval*2 : max(100_000,interval*3)
        if let ageMicros,ageMicros > UInt64(ageLimit) { return result(.drop(.late)) }
        if frameRate != self.frameRate {
            pendingResynchronization=hasAcceptedFrame
            self.frameRate=frameRate;anchorSource=nil;sourceSteps=[];nextStep=0
        }
        noteSource(sourcePTS)
        // A game slower than the stream arrives at its own pace: the stream's interval is too short a buffer.
        let frameTime=mode == .balanced || mode == .smoothest ? contentInterval(atLeast:interval) : interval
        let buffer=mode == .smoothest ? frameTime*2 : frameTime
        if mode == .lowLatency {
            return result(.enqueue(timeMicros:rendererNow,late:ageMicros.map { $0 > UInt64(interval) } ?? false,
                                   resynchronize:pendingResynchronization))
        }
        if mode == .pcFrameTimes {
            guard sourcePTS <= Int64.max/4,rendererNow <= Int64.max/4 else { return result(.drop(.invalidTimestamp)) }
            let ready=max(0,rendererNow-Int64(ageMicros ?? 0))
            if let refreshGrid {
                let schedule=clock.schedule(hostMicros:sourcePTS,readyMicros:ready,grid:refreshGrid)
                holdMicros=schedule.holdMicros;sharesRefresh=schedule.sharesRefresh
                return result(.enqueue(timeMicros:max(schedule.releaseMicros,rendererNow),late:schedule.late,
                                       resynchronize:pendingResynchronization))
            }
            let schedule=clock.schedule(hostMicros:sourcePTS,readyMicros:ready)
            holdMicros=schedule.holdMicros
            return result(.enqueue(timeMicros:max(schedule.presentMicros,rendererNow),late:schedule.late,
                                   resynchronize:pendingResynchronization))
        }
        if mode == .fpsLimit {
            // Nightjar's `cap_slot`: a frame after the last slot, never before now or over a frame away.
            guard rendererNow <= Int64.max-interval else { return result(.drop(.invalidTimestamp)) }
            let slot=lastSlot.map { min(max($0+interval,rendererNow),rendererNow+interval) } ?? rendererNow
            plannedSlot=slot
            return result(.enqueue(timeMicros:slot,late:ageMicros.map { $0 > UInt64(interval) } ?? false,
                                   resynchronize:pendingResynchronization))
        }
        if anchorSource == nil {
            anchorSource=sourcePTS
            let (anchor,overflow)=rendererNow.addingReportingOverflow(buffer)
            guard !overflow else { anchorSource=nil;return result(.drop(.invalidTimestamp)) }
            anchorRenderer=anchor;anchorBuffer=buffer;earlyOrLateStrikes=0
        }
        let (step,stepOverflow)=sourcePTS.subtractingReportingOverflow(anchorSource!)
        let (target,targetOverflow)=anchorRenderer.addingReportingOverflow(step)
        guard !stepOverflow,!targetOverflow else { return result(.drop(.invalidTimestamp)) }
        let (lead,leadOverflow)=target.subtractingReportingOverflow(rendererNow)
        guard !leadOverflow else { return result(.drop(.invalidTimestamp)) }
        // Elapsed beyond the PC's own step: a slow game's long gaps between frames are not a stall.
        let stalled=lastAcceptedAt.map { rendererNow >= $0 && rendererNow-$0 > max(0,sourcePTS-(lastSourcePTS ?? sourcePTS))+100_000 } ?? false
        let resized=abs(buffer-anchorBuffer)*4 > anchorBuffer
        let early=lead > buffer*2,lateBy=lead < -frameTime*2
        // A corrupt PTS has gone above. One frame out of line is jitter; several mean the timeline
        // really is off, such as anchored on a late frame after a network spike.
        earlyOrLateStrikes=early || lateBy ? earlyOrLateStrikes+1 : 0
        if stalled || resized || earlyOrLateStrikes >= Self.strikesToRealign {
            anchorSource=sourcePTS;earlyOrLateStrikes=0
            let (anchor,overflow)=rendererNow.addingReportingOverflow(buffer)
            guard !overflow else { return result(.drop(.invalidTimestamp)) }
            anchorRenderer=anchor;anchorBuffer=buffer;pendingResynchronization=hasAcceptedFrame
            return result(.enqueue(timeMicros:anchor,late:lead < 0,resynchronize:pendingResynchronization))
        }
        // An outlying early frame goes at the buffer's edge: waiting, the next would replace it.
        if early { return result(.enqueue(timeMicros:rendererNow+buffer,late:false,resynchronize:pendingResynchronization)) }
        // Do not feed the renderer further ahead than the mode's buffer.
        if lead > buffer { return result(.wait(microseconds:UInt64(lead-buffer))) }
        return result(.enqueue(timeMicros:max(0,target),late:lead < 0,resynchronize:pendingResynchronization))
    }
    public mutating func accepted(sourcePTS: Int64,rendererNow: Int64) {
        lastSourcePTS=sourcePTS;lastAcceptedAt=rendererNow;pendingResynchronization=false;futureStrikes=0
        lastSlot=plannedSlot ?? lastSlot
    }
    /// Whether a newer waiting frame replaces this one. The in-order pacings skip a frame only once
    /// it is over a frame old (Nightjar's `take_due`); an unknown age stays, bounded by the mailbox.
    public func isSuperseded(ageMicros: UInt64?,frameRate: UInt32) -> Bool {
        guard mode.keepsOrder else { return true }
        guard let ageMicros,frameRate > 0 else { return false }
        return ageMicros > UInt64((1_000_000 + Int64(frameRate)/2)/Int64(frameRate))
    }
    private static let strikesToRealign=3
    /// The longest frame time the buffer follows, so an idle desktop does not add a long delay.
    private static let longestFrameTime: Int64=50_000
    private mutating func noteSource(_ source: Int64) {
        defer { lastSeenSource=source }
        guard let lastSeenSource,source > lastSeenSource else { return }
        if sourceSteps.count < 31 { sourceSteps.append(source-lastSeenSource) } else { sourceSteps[nextStep]=source-lastSeenSource }
        nextStep=(nextStep+1)%31
    }
    /// The median gap between recent frames on the PC, once there are enough to say.
    private func contentInterval(atLeast interval: Int64) -> Int64 {
        guard sourceSteps.count >= 8 else { return interval }
        return max(interval,min(sourceSteps.sorted()[sourceSteps.count/2],Self.longestFrameTime))
    }
    private mutating func futureTimestamp() -> FramePacingPlan {
        futureStrikes=min(2,futureStrikes+1)
        return FramePacingPlan(action:futureStrikes == 1 ? .drop(.invalidTimestamp) : .recoverTimestamp)
    }
}

public struct PresentationMetrics: Sendable, Equatable {
    public private(set) var drops: [PresentationDropReason: UInt64] = [:]
    public private(set) var lateFrames: UInt64 = 0
    public private(set) var queueDepth: Int = 0
    public private(set) var peakQueueDepth: Int = 0
    public private(set) var resynchronizations: UInt64 = 0
    public private(set) var rendererDroppedFrames: UInt64?
    public private(set) var rendererCorruptedFrames: UInt64?
    public private(set) var holdMicros: Int64?
    public private(set) var sharedRefreshes: UInt64=0
    public private(set) var cadence=ShownCadence()
    public var droppedFrames: UInt64 { drops.values.reduce(0,&+) }
    public init() {}
    public mutating func drop(_ reason: PresentationDropReason,count: UInt64 = 1) {
        drops[reason,default:0] &+= count
        if reason == .late { lateFrames &+= count }
    }
    public mutating func late() { lateFrames &+= 1 }
    public mutating func queue(depth: Int) { queueDepth=max(0,min(4,depth));peakQueueDepth=max(peakQueueDepth,queueDepth) }
    public mutating func resynchronize() { resynchronizations &+= 1 }
    public mutating func hold(micros: Int64) { holdMicros=micros }
    public mutating func sharedRefresh() { sharedRefreshes &+= 1 }
    public mutating func shown(_ cadence: ShownCadence) { self.cadence=cadence }
    public mutating func renderer(dropped: UInt64?,corrupted: UInt64?) {
        rendererDroppedFrames=dropped;rendererCorruptedFrames=corrupted
    }
}
