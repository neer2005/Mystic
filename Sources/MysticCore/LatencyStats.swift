import Foundation

/// Fixed-capacity latency recorder.
///
/// Every stage of the pipeline reports durations in microseconds; this keeps a
/// rolling window and answers the questions latency work actually asks: what is
/// typical (p50), what do I feel (p95), and what is the worst case (p99).
///
/// A ring buffer rather than a growing array because this runs on the streaming
/// hot path and must not allocate per frame.
public struct LatencyStats: Sendable, Equatable {

    public let capacity: Int
    private var storage: [Int64]
    private var next = 0
    private var filled = 0
    private var total: Int64 = 0

    public init(capacity: Int = 600) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
    }

    public var count: Int { filled }
    public var isEmpty: Bool { filled == 0 }

    public mutating func record(microseconds value: Int64) {
        if filled == capacity {
            total -= storage[next]
        } else {
            filled += 1
        }
        storage[next] = value
        total += value
        next = (next + 1) % capacity
    }

    public var mean: Double? {
        guard filled > 0 else { return nil }
        return Double(total) / Double(filled)
    }

    /// Nearest-rank percentile: returns an actual observed sample rather than an
    /// interpolated value, which is what latency reporting should quote.
    /// `p` is clamped to 0...1.
    public func percentile(_ p: Double) -> Int64? {
        guard filled > 0 else { return nil }
        let sorted = Array(storage.prefix(filled)).sorted()
        let clamped = min(max(p, 0), 1)
        // rank = ceil(p * N), 1-based, clamped into range.
        let rank = max(1, Int((clamped * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    /// Mean absolute difference between consecutive samples — the jitter metric
    /// that matters for frame pacing, not for network loss.
    public var meanAbsoluteJitter: Double? {
        guard filled > 1 else { return nil }
        let samples = Array(storage.prefix(filled))
        var sum: Int64 = 0
        for i in 1..<samples.count {
            sum += abs(samples[i] - samples[i - 1])
        }
        return Double(sum) / Double(samples.count - 1)
    }

    public mutating func reset() {
        storage = Array(repeating: 0, count: capacity)
        next = 0
        filled = 0
        total = 0
    }
}

/// The stages a frame passes through between the host's encoder and the display.
///
/// Recorded separately so a regression can be attributed to a stage instead of
/// showing up as an unexplained increase in total latency.
public enum LatencyStage: String, Sendable, CaseIterable {
    case network        // host send -> local receive
    case depacketize    // RTP reassembly into a frame
    case decode         // decoder in -> decoded frame out
    case present        // decoded frame -> first frame on screen
    case glassToGlass   // host encode timestamp -> screen
}

/// One recorder per stage, with a bounded window so memory is predictable.
public struct LatencyHistogram: Sendable {
    public var stage: LatencyStage
    public var stats: LatencyStats

    public init(stage: LatencyStage, capacity: Int = 600) {
        self.stage = stage
        self.stats = LatencyStats(capacity: capacity)
    }
}

/// A complete set of per-stage recorders for a session.
public struct SessionLatency: Sendable {
    private var histograms: [LatencyStage: LatencyHistogram]

    public init(capacity: Int = 600) {
        var built: [LatencyStage: LatencyHistogram] = [:]
        for stage in LatencyStage.allCases {
            built[stage] = LatencyHistogram(stage: stage, capacity: capacity)
        }
        self.histograms = built
    }

    public mutating func record(_ stage: LatencyStage, microseconds: Int64) {
        histograms[stage]?.stats.record(microseconds: microseconds)
    }

    public func histogram(_ stage: LatencyStage) -> LatencyStats? {
        histograms[stage]?.stats
    }

    /// Human-readable summary, in milliseconds, for the stats overlay and logs.
    public func summary() -> [String: String] {
        var out: [String: String] = [:]
        for stage in LatencyStage.allCases {
            guard let stats = histograms[stage]?.stats, let p50 = stats.percentile(0.5) else { continue }
            let p95 = stats.percentile(0.95) ?? p50
            out[stage.rawValue] = String(format: "p50 %.2f ms / p95 %.2f ms",
                                         Double(p50) / 1000.0, Double(p95) / 1000.0)
        }
        return out
    }
}
