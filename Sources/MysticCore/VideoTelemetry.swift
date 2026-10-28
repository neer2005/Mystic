/// Measured boundaries only. Renderer enqueue is not a display/scanout timestamp.
public enum VideoTimingStage: String, Sendable, CaseIterable {
    case hostProcessing, reassembly, decode, displayWait, rendererEnqueue, clientToEnqueue
    public var label: String {
        switch self {
        case .hostProcessing: "Host processing"
        case .reassembly: "Frame assembly"
        case .decode: "VideoToolbox decode"
        case .displayWait: "Decode → renderer"
        case .rendererEnqueue: "Renderer enqueue"
        case .clientToEnqueue: "Client submit → enqueue"
        }
    }
}

public struct VideoTimingSummary: Sendable, Equatable {
    public let count: Int
    public let p50Micros: Int64
    public let p95Micros: Int64
}

public struct VideoTelemetrySnapshot: Sendable, Equatable {
    public let timings: [VideoTimingStage: VideoTimingSummary]
    public let submitted: UInt64
    public let decoded: UInt64
    public let enqueued: UInt64
    /// Rates since the previous snapshot; absent until an interval has elapsed.
    public let decodedFPS: Double?
    public let enqueuedFPS: Double?
}

/// Bounded rolling measurements; snapshot sorting happens only at the HUD polling rate.
/// Engine receive/enqueue timestamps share an engine clock. Local timestamps share
/// a separate monotonic clock. These two clock origins must never be subtracted.
public struct VideoTelemetryAccumulator: Sendable {
    private var stats: [VideoTimingStage: LatencyStats]
    private var submitted: UInt64 = 0, decoded: UInt64 = 0, enqueued: UInt64 = 0
    private var previous: (time: UInt64, decoded: UInt64, enqueued: UInt64)?
    public init(capacity: Int = 600) {
        stats=Dictionary(uniqueKeysWithValues:VideoTimingStage.allCases.map { ($0,LatencyStats(capacity:capacity)) })
    }
    public static func duration(from start: UInt64,to end: UInt64) -> Int64? {
        guard end >= start,end-start <= 60_000_000 else { return nil }
        return Int64(end-start)
    }
    private mutating func record(_ stage: VideoTimingStage,_ value: Int64?) {
        if let value { stats[stage]?.record(microseconds:value) }
    }
    public mutating func submit(hostTenthMs: UInt16,receiveMicros: UInt64,completeMicros: UInt64) {
        submitted &+= 1
        // The protocol uses zero for an unreported host value.
        if hostTenthMs != 0 { record(.hostProcessing,Int64(hostTenthMs)*100) }
        record(.reassembly,Self.duration(from:receiveMicros,to:completeMicros))
    }
    public mutating func decode(startMicros: UInt64,endMicros: UInt64) {
        decoded &+= 1
        record(.decode,Self.duration(from:startMicros,to:endMicros))
    }
    public mutating func enqueue(submitMicros: UInt64,decodedMicros: UInt64,startMicros: UInt64,endMicros: UInt64) {
        enqueued &+= 1
        record(.displayWait,Self.duration(from:decodedMicros,to:startMicros))
        record(.rendererEnqueue,Self.duration(from:startMicros,to:endMicros))
        record(.clientToEnqueue,Self.duration(from:submitMicros,to:endMicros))
    }
    public mutating func snapshot(nowMicros: UInt64) -> VideoTelemetrySnapshot {
        var summaries: [VideoTimingStage: VideoTimingSummary]=[:]
        for stage in VideoTimingStage.allCases {
            guard let samples=stats[stage],let p50=samples.percentile(0.5),let p95=samples.percentile(0.95) else { continue }
            summaries[stage]=VideoTimingSummary(count:samples.count,p50Micros:p50,p95Micros:p95)
        }
        var decodedFPS: Double?,enqueuedFPS: Double?
        if let previous,nowMicros > previous.time {
            let seconds=Double(nowMicros-previous.time)/1_000_000
            decodedFPS=Double(decoded-previous.decoded)/seconds
            enqueuedFPS=Double(enqueued-previous.enqueued)/seconds
        }
        // Equal/regressed poll timestamps cannot poison the next rate interval.
        if previous == nil || nowMicros > previous!.time { previous=(nowMicros,decoded,enqueued) }
        return VideoTelemetrySnapshot(timings:summaries,submitted:submitted,decoded:decoded,enqueued:enqueued,
                                      decodedFPS:decodedFPS,enqueuedFPS:enqueuedFPS)
    }
}

/// Same local monotonic clock for decoder entry, completion and renderer enqueue.
public struct VideoFrameTiming: Sendable {
    public let submitMicros: UInt64
    public let decodedMicros: UInt64
    public init(submitMicros: UInt64,decodedMicros: UInt64) {
        self.submitMicros=submitMicros;self.decodedMicros=decodedMicros
    }
}
