import Foundation

/// Nightjar's playout rule (`playout.rs`) on Mystic's decode side. The output reads a ring on the
/// real-time thread, so instead of filling a device that asks for more than is queued, a tick
/// at the packet rate sees a packet that is late while the ring is nearly empty and fills its
/// time with Opus concealment before the output runs dry. The packet whose time concealment
/// played is skipped when it arrives, so riding out a late burst never adds latency.
/// Concealment stops after 100 ms of outage; what arrives after that is new, not late.
struct AudioPlayout {
    /// The longest outage concealed, in ms. Opus fades its concealment out well before this.
    static let concealMs=100
    let packetFrames: Int
    /// Concealment starts once the ring holds less than this: the next output read would starve.
    let lowWater: Int
    private let packetNanos: UInt64
    private var owed=0,run=0
    private var primed=false
    private var lastArrival: UInt64=0
    private(set) var skipped: UInt64=0

    /// `outputFrames` is how much the output takes at once (0 when unknown).
    init(packetMs: Int,outputFrames: Int = 0) {
        packetFrames=48*max(1,packetMs)
        packetNanos=UInt64(max(1,packetMs))*1_000_000
        lowWater=max(2*packetFrames,480,outputFrames)
    }
    /// A packet from the stream (`lost` for one the engine gave up on). False: its time was
    /// already concealed, so it is skipped.
    mutating func packet(lost: Bool,nowNanos: UInt64) -> Bool {
        lastArrival=nowNanos
        if owed > 0 { owed -= 1;skipped += 1;return false }
        if !lost { run=0;primed=true }
        return true
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
