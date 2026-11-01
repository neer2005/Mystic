import Foundation

/// Nightjar's playout rule (`playout.rs`) on Mystic's decode side. A packet that arrives on an
/// empty queue (the first, or after an outage) is led with silence, so the next packet's jitter
/// does not starve the output again. The output reads a ring on the real-time thread, so instead
/// of filling a device that asks for more than is queued, a tick at the packet rate sees a packet
/// that is late while the next read would run dry and fills its time with Opus concealment. The
/// packet whose time concealment played is skipped when it arrives, so riding out a late burst
/// never adds latency. Concealment stops after 100 ms of outage; what arrives after that is new.
struct AudioPlayout {
    /// The longest outage concealed, in ms. Opus fades its concealment out well before this.
    static let concealMs=100
    /// Nightjar's lead: 10 ms of silence on an empty queue, here past one output read.
    static let leadMs=10
    /// What the output is assumed to read at once until it says: macOS's usual 512 frames.
    static let defaultReadFrames=512
    let packetFrames: Int
    /// How much the output takes at once, in 48 kHz frames (0 when unknown).
    var outputFrames: Int
    private let packetNanos: UInt64
    private var owed=0,run=0
    private var primed=false
    private var lastArrival: UInt64=0
    private(set) var skipped: UInt64=0

    enum Arrival: Equatable {
        /// Its time was already concealed.
        case skip
        /// Play it, after `lead` frames of silence.
        case play(lead: Int)
    }
    init(packetMs: Int,outputFrames: Int = 0) {
        packetFrames=48*max(1,packetMs)
        packetNanos=UInt64(max(1,packetMs))*1_000_000
        self.outputFrames=outputFrames
    }
    private var readFrames: Int { outputFrames > 0 ? outputFrames : Self.defaultReadFrames }
    /// Concealment starts once the ring holds less than the output's next read.
    var lowWater: Int { max(packetFrames,readFrames) }
    /// Silence led with on an empty queue.
    var lead: Int { 48*Self.leadMs+readFrames }
    /// A packet from the stream (`lost` for one the engine gave up on), with `queued` frames in
    /// the ring.
    mutating func packet(lost: Bool,queued: Int,nowNanos: UInt64) -> Arrival {
        lastArrival=nowNanos
        if owed > 0 { owed -= 1;skipped += 1;return .skip }
        guard !lost else { return .play(lead:0) }
        let lead=(!primed || queued == 0) ? self.lead : 0
        run=0;primed=true
        return .play(lead:lead)
    }
    /// How many packets' worth to conceal now, given `queued` frames in the ring.
    mutating func tick(queued: Int,nowNanos: UInt64) -> Int {
        guard primed,queued < lowWater,nowNanos >= lastArrival,nowNanos-lastArrival >= packetNanos else { return 0 }
        let room=(48*Self.concealMs-run)/packetFrames
        guard room > 0 else {
            // Past what concealment rides out: what arrives next is new, not late.
            owed=0;return 0
        }
        let packets=min(room,(lowWater-queued+packetFrames-1)/packetFrames)
        owed += packets;run += packets*packetFrames
        return packets
    }
    /// Playback moved elsewhere or stopped: nothing is concealed until a packet plays again.
    mutating func reset() { primed=false;owed=0;run=0 }
}
