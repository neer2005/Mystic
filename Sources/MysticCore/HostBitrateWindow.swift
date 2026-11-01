/// Automatic bitrate on a Foundation Sunshine host, which runs the controller itself: the
/// client reports its network every three seconds and takes the bitrate the host chose.
/// Nightjar's desktop `HostAbr` (`stream/host_abr.rs`), after Moonlight V+ PC.
public struct HostBitrateWindow: Sendable, Equatable {
    /// Moonlight V+ PC's `ABR_FEEDBACK_INTERVAL_MS`.
    public static let intervalMillis: UInt64 = 3000
    /// The bitrate the host last set, in kbps.
    public private(set) var currentKbps: UInt32
    private var frames: UInt64 = 0, drops: UInt64 = 0, decoded: UInt64 = 0
    private var windowStart: UInt64
    private var inFlight = false

    /// The host's controller is on from `nowMillis`, at its initial bitrate, else the stream's.
    public init(initialKbps: UInt32,streamKbps: UInt32,nowMillis: UInt64) {
        currentKbps=initialKbps > 0 ? initialKbps : streamKbps;windowStart=nowMillis
    }
    /// One tick: frames completed and dropped by the network, and frames decoded.
    public mutating func add(completed: UInt64,dropped: UInt64,decoded: UInt64) {
        frames+=completed+dropped;drops+=dropped;self.decoded+=decoded
    }
    /// The report for the window ending at `nowMillis`, once three seconds have passed and the
    /// last report was answered. Starts the next window.
    public mutating func due(nowMillis: UInt64,rttMillis: Double?) -> HostBitrateFeedback? {
        let elapsed=nowMillis >= windowStart ? nowMillis-windowStart : 0
        guard !inFlight,elapsed >= Self.intervalMillis else { return nil }
        let report=HostBitrateFeedback(packetLoss:frames == 0 ? 0 : min(100,Double(drops)*100/Double(frames)),
            rttMs:rttMillis ?? 0,decodeFps:Double(decoded)*1000/Double(elapsed),
            droppedFrames:UInt32(clamping:drops),currentKbps:currentKbps)
        frames=0;drops=0;decoded=0;windowStart=nowMillis;inFlight=true
        return report
    }
    /// The host's answer to the last report (nil when it failed): the bitrate it moved to, if it moved.
    public mutating func answered(newKbps: UInt32?) -> UInt32? {
        inFlight=false
        guard let newKbps,newKbps > 0,newKbps != currentKbps else { return nil }
        currentKbps=newKbps
        return newKbps
    }
}

/// `POST /api/abr/feedback`: this client's network since the last report.
public struct HostBitrateFeedback: Codable, Sendable, Equatable {
    /// Lost video frames in percent, 0 to 100.
    public let packetLoss: Double
    public let rttMs: Double
    public let decodeFps: Double
    public let droppedFrames: UInt32
    public let currentKbps: UInt32
}
