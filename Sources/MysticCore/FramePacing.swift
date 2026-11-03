/// Nightjar's `config::FramePacing`: how decoded pictures wait for the display without VRR.
public enum FramePacingMode: String, CaseIterable, Hashable, Sendable {
    case lowLatency = "lowLatency"
    case balanced = "balanced"
    case fpsLimit = "fpsLimit"
    case smoothest = "smoothest"
    public var label: String {
        switch self {
        case .lowLatency: "Lowest Latency"
        case .balanced: "Balanced"
        case .fpsLimit: "Balanced with FPS Limit"
        case .smoothest: "Smoothest Video (More Delay)"
        }
    }
    public var detail: String {
        switch self {
        case .lowLatency: "Shows the newest picture as soon as it can. Adds no delay."
        case .balanced: "Always waits for the display, so the picture never tears."
        case .fpsLimit: "Waits for the display and limits frames to the stream's rate. Can add up to a frame of delay."
        case .smoothest: "Shows every picture in turn. The smoothest motion, with the most delay."
        }
    }
    /// Every mode but the lowest latency waits for the refresh.
    public var forcesVsync: Bool { self != .lowLatency }
}
/// An unknown stored value, such as the removed PC Frame Times choice, is the default.
extension FramePacingMode: Codable {
    public init(from decoder: any Decoder) throws {
        self=FramePacingMode(rawValue:try decoder.singleValueContainer().decode(String.self)) ?? .lowLatency
    }
}

public enum PresentationDropReason: String, CaseIterable, Hashable, Sendable {
    case superseded, late, outOfOrder, invalidTimestamp, reset, enqueueFailure
}

/// Nightjar's `stream::present::PacingMode`, without the beam race.
public enum PresentationPacing: Sendable, Equatable {
    case hostTimes,immediate,vsync
    /// `pacing`: host times need VRR, which needs a display that can tear and the check that it
    /// refreshes on present. Mystic has no such check yet, so it passes `tearingSupported` false.
    public static func choose(vrr: Bool,presentAtHostTimes: Bool,vsync: Bool,framePacing: FramePacingMode,tearingSupported: Bool) -> PresentationPacing {
        if vrr && tearingSupported { return presentAtHostTimes ? .hostTimes : .immediate }
        return withoutVRR(vsync:vsync,framePacing:framePacing)
    }
    public static func withoutVRR(vsync: Bool,framePacing: FramePacingMode) -> PresentationPacing {
        vsync || framePacing.forcesVsync ? .vsync : .immediate
    }
    /// Host-time pacing schedules every picture; the other modes keep only the newest.
    public var mailboxLimit: Int { self == .hostTimes ? 8 : 2 }
}

/// Nightjar's `stream::present::Pacer`: when each decoded picture goes to the screen. No clock or
/// I/O; times are microseconds on one clock.
public struct PresentationPacer<Picture>: Sendable where Picture: Sendable {
    public struct Pending: Sendable {
        public let picture: Picture
        public let readyMicros: Int64
        public let presentMicros: Int64
        public let holdMicros: Int64
        public let late: Bool
    }
    public let mode: PresentationPacing
    public private(set) var clock=PresentClock()
    private var pending: [Pending]=[]
    private let framePacing: FramePacingMode
    private var frameMicros: Int64
    private var lastSlot: Int64?
    public init(mode: PresentationPacing,framePacing: FramePacingMode,frameRate: UInt32 = 60,minIntervalMicros: Int64 = 0) {
        self.mode=mode;self.framePacing=framePacing;frameMicros=Self.frameMicros(frameRate)
        clock.minIntervalMicros=minIntervalMicros
    }
    /// The longest a picture waits in the in-order pacings: one frame, at most 250 ms.
    public static func frameMicros(_ frameRate: UInt32) -> Int64 { min(1_000_000/Int64(max(frameRate,1)),250_000) }
    public mutating func set(frameRate: UInt32) { frameMicros=Self.frameMicros(frameRate) }
    public var nextDueMicros: Int64? { pending.first?.presentMicros }
    public var lastHoldMicros: Int64? { mode == .hostTimes ? lastHold : nil }
    private var lastHold: Int64?
    private func paced(_ pacing: FramePacingMode) -> Bool { mode == .vsync && framePacing == pacing }
    private mutating func capSlot(ready: Int64) -> Int64 {
        let slot=lastSlot.map { min(max($0+frameMicros,ready),ready+frameMicros) } ?? ready
        lastSlot=slot
        return slot
    }
    /// Takes a newly decoded picture, scheduling it once, in order.
    public mutating func accept(_ picture: Picture,readyMicros ready: Int64,hostMicros: Int64) {
        var present=ready,hold: Int64=0,late=false
        if mode == .hostTimes {
            let schedule=clock.schedule(hostMicros:hostMicros,readyMicros:ready)
            (present,hold,late)=(schedule.presentMicros,schedule.holdMicros,schedule.late)
        } else if paced(.fpsLimit) {
            present=capSlot(ready:ready);hold=present-ready
        }
        pending.append(Pending(picture:picture,readyMicros:ready,presentMicros:present,holdMicros:hold,late:late))
    }
    /// The newest picture due at `now`; older due ones are dropped. With the FPS limit or the
    /// smoothest pacing it is the oldest due picture, one a refresh: an older one is dropped only
    /// once it is over a frame old and a newer one is due.
    public mutating func takeDue(now: Int64) -> (picture: Pending?,dropped: Int) {
        var chosen: Pending?,dropped=0
        if paced(.fpsLimit) || paced(.smoothest) {
            while pending.count > 1,pending[1].presentMicros <= now,now-pending[0].readyMicros > frameMicros {
                pending.removeFirst();dropped+=1
            }
            if let first=pending.first,first.presentMicros <= now { chosen=pending.removeFirst() }
        } else {
            while let first=pending.first,first.presentMicros <= now {
                if chosen != nil { dropped+=1 }
                chosen=pending.removeFirst()
            }
        }
        if let chosen { lastHold=chosen.holdMicros }
        return (chosen,dropped)
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
    public private(set) var phaseLeadMicros: Int32?
    public private(set) var cadence=ShownCadence()
    public var droppedFrames: UInt64 { drops.values.reduce(0,&+) }
    public init() {}
    public mutating func drop(_ reason: PresentationDropReason,count: UInt64 = 1) {
        drops[reason,default:0] &+= count
        if reason == .late { lateFrames &+= count }
    }
    public mutating func late() { lateFrames &+= 1 }
    public mutating func queue(depth: Int) { queueDepth=max(0,min(9,depth));peakQueueDepth=max(peakQueueDepth,queueDepth) }
    public mutating func resynchronize() { resynchronizations &+= 1 }
    public mutating func hold(micros: Int64) { holdMicros=micros }
    public mutating func phase(leadMicros: Int32) { phaseLeadMicros=leadMicros }
    public mutating func shown(_ cadence: ShownCadence) { self.cadence=cadence }
    public mutating func renderer(dropped: UInt64?,corrupted: UInt64?) {
        rendererDroppedFrames=dropped;rendererCorruptedFrames=corrupted
    }
}
