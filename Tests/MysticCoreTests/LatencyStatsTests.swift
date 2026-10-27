import Testing
@testable import MysticCore

@Suite("Latency statistics")
struct LatencyStatsTests {

    @Test("an empty recorder has no answers")
    func empty() {
        let stats = LatencyStats(capacity: 8)
        #expect(stats.isEmpty)
        #expect(stats.mean == nil)
        #expect(stats.percentile(0.5) == nil)
        #expect(stats.meanAbsoluteJitter == nil)
    }

    @Test("mean is computed over the recorded samples")
    func mean() {
        var stats = LatencyStats(capacity: 8)
        for value: Int64 in [1000, 2000, 3000] { stats.record(microseconds: value) }
        #expect(stats.count == 3)
        #expect(stats.mean == 2000)
    }

    @Test("the ring buffer keeps only the newest samples")
    func wrap() {
        var stats = LatencyStats(capacity: 3)
        for value: Int64 in [10, 20, 30, 40, 50] { stats.record(microseconds: value) }
        #expect(stats.count == 3)
        // Window holds 30, 40, 50.
        #expect(stats.mean == 40)
        #expect(stats.percentile(0) == 30)
        #expect(stats.percentile(1) == 50)
    }

    @Test("percentiles use nearest rank")
    func percentiles() {
        var stats = LatencyStats(capacity: 100)
        for value in stride(from: Int64(1), through: 100, by: 1) {
            stats.record(microseconds: value)
        }
        #expect(stats.percentile(0.5) == 50)
        #expect(stats.percentile(0.95) == 95)
        #expect(stats.percentile(0.99) == 99)
    }

    @Test("jitter measures frame-to-frame variation")
    func jitter() {
        var stats = LatencyStats(capacity: 8)
        for value: Int64 in [1000, 1000, 1000, 1000] { stats.record(microseconds: value) }
        #expect(stats.meanAbsoluteJitter == 0)

        var varying = LatencyStats(capacity: 8)
        for value: Int64 in [1000, 3000, 1000, 3000] { varying.record(microseconds: value) }
        #expect(varying.meanAbsoluteJitter == 2000)
    }

    @Test("reset clears the window")
    func reset() {
        var stats = LatencyStats(capacity: 4)
        stats.record(microseconds: 500)
        stats.reset()
        #expect(stats.isEmpty)
        #expect(stats.mean == nil)
    }

    @Test("a session histogram reports per-stage figures")
    func session() {
        var session = SessionLatency(capacity: 16)
        session.record(.decode, microseconds: 4000)
        session.record(.decode, microseconds: 6000)
        session.record(.network, microseconds: 1000)

        let decode = session.histogram(.decode)
        #expect(decode?.count == 2)
        // Nearest rank over {4000, 6000} at p50 is an observed sample, not a
        // synthetic midpoint.
        #expect(decode?.percentile(0.5) == 4000)

        let summary = session.summary()
        #expect(summary["decode"] == "p50 4.00 ms / p95 6.00 ms")
        #expect(summary["network"] == "p50 1.00 ms / p95 1.00 ms")
        // Stages with no samples are omitted rather than reported as zero.
        #expect(summary["present"] == nil)
    }
}
