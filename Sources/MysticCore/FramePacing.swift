/// Presentation policy only: source PTS and the renderer clock have independent origins.
public enum FramePacingMode: String, CaseIterable, Codable, Hashable, Sendable {
    case lowLatency = "lowLatency"
    case balanced = "balanced"
    public var label: String { self == .lowLatency ? "Low Latency" : "Balanced" }
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
    private var pendingResynchronization = false
    private var futureStrikes = 0
    public init(mode: FramePacingMode = .lowLatency) { self.mode=mode }
    public mutating func reset() { self=FramePacer(mode:mode) }

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
            self.frameRate=frameRate;anchorSource=nil
        }
        if mode == .lowLatency {
            return result(.enqueue(timeMicros:rendererNow,late:ageMicros.map { $0 > UInt64(interval) } ?? false,
                                   resynchronize:pendingResynchronization))
        }
        if anchorSource == nil {
            anchorSource=sourcePTS
            let (anchor,overflow)=rendererNow.addingReportingOverflow(interval)
            guard !overflow else { anchorSource=nil;return result(.drop(.invalidTimestamp)) }
            anchorRenderer=anchor
        }
        let (step,stepOverflow)=sourcePTS.subtractingReportingOverflow(anchorSource!)
        let (target,targetOverflow)=anchorRenderer.addingReportingOverflow(step)
        guard !stepOverflow,!targetOverflow else { return result(.drop(.invalidTimestamp)) }
        let (lead,leadOverflow)=target.subtractingReportingOverflow(rendererNow)
        guard !leadOverflow else { return result(.drop(.invalidTimestamp)) }
        // A single corrupt future PTS must not move the timeline or poison source ordering.
        guard lead <= 100_000 else { return futureTimestamp() }
        let stalled=lastAcceptedAt.map { rendererNow >= $0 && rendererNow-$0 > 100_000 } ?? false
        if lead < -interval*2 || stalled {
            anchorSource=sourcePTS
            let (anchor,overflow)=rendererNow.addingReportingOverflow(interval)
            guard !overflow else { return result(.drop(.invalidTimestamp)) }
            anchorRenderer=anchor;pendingResynchronization=hasAcceptedFrame
            return result(.enqueue(timeMicros:anchor,late:lead < 0,resynchronize:pendingResynchronization))
        }
        // Do not feed the native renderer more than one frame into the future.
        if lead > interval { return result(.wait(microseconds:UInt64(lead-interval))) }
        return result(.enqueue(timeMicros:max(0,target),late:lead < 0,resynchronize:pendingResynchronization))
    }
    public mutating func accepted(sourcePTS: Int64,rendererNow: Int64) {
        lastSourcePTS=sourcePTS;lastAcceptedAt=rendererNow;pendingResynchronization=false;futureStrikes=0
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
    public var droppedFrames: UInt64 { drops.values.reduce(0,&+) }
    public init() {}
    public mutating func drop(_ reason: PresentationDropReason,count: UInt64 = 1) {
        drops[reason,default:0] &+= count
        if reason == .late { lateFrames &+= count }
    }
    public mutating func late() { lateFrames &+= 1 }
    public mutating func queue(depth: Int) { queueDepth=max(0,min(2,depth));peakQueueDepth=max(peakQueueDepth,queueDepth) }
    public mutating func resynchronize() { resynchronizations &+= 1 }
    public mutating func renderer(dropped: UInt64?,corrupted: UInt64?) {
        rendererDroppedFrames=dropped;rendererCorruptedFrames=corrupted
    }
}
