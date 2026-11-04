import Foundation

/// Nightjar's playout rule (`playout.rs`) on Mystic's decode side. A packet that arrives on an
/// empty queue (the first, or after an outage) is led with silence, so the next packet's jitter
/// does not starve the output again. The output reads a ring on the real-time thread, so instead
/// of filling a device that asks for more than is queued, a tick at the packet rate (at most every
/// 5 ms, `minTickMs`) sees a packet that is late while the next read would run dry and fills its
/// time with concealment: Opus's, or silence for PCM. The
/// packet whose time concealment played is skipped when it arrives, so riding out a late burst
/// never adds latency. Concealment stops after 100 ms of outage; what arrives after that is new.
/// A device clock slower than the host's builds up a surplus; it is trimmed a packet at a time,
/// faded, long before the ring's limit.
struct AudioPlayout {
    /// The longest outage concealed, in ms. Opus fades its concealment out well before this.
    static let concealMs=100
    /// Nightjar's lead: 10 ms of silence on an empty queue, here past one output read.
    static let leadMs=10
    /// What the output is assumed to read at once until it says: macOS's usual 512 frames.
    static let defaultReadFrames=512
    /// 60 ms, enough at the usual read.
    static let minRingLimit=2880
    /// A queue more than a packet above the lead for this long, in ms of packets, is surplus a slow
    /// device clock built up, and one packet goes. Steady state never stays there: any packet within
    /// a packet of the lead starts the count again.
    static let trimAfterMs=2000
    /// The fade from a trimmed packet into the next, in ms.
    static let fadeMs=5
    /// The shortest gap between late-packet ticks, in ms. Nightjar conceals when the device asks
    /// for more than is queued, so its wakeups follow the device's reads whatever the packet size.
    /// Core Audio's real-time thread can't decode here, so Mystic ticks a timer instead: at the
    /// packet rate, but no more often than a 5 ms Opus stream already does. Rubylight's 7.1 PCM
    /// comes in 1 ms packets; ticking per packet would mean 1,000 wakeups a second for no gain,
    /// since `tick` fills the whole shortfall in whole packets, as Nightjar's `starve` does.
    static let minTickMs=5
    /// How often the late-packet timer ticks for `packetMs` packets, in ms.
    static func tickMs(packetMs: Int) -> Int { max(packetMs,minTickMs) }
    let packetFrames: Int
    /// How much the output takes at once, in 48 kHz frames (0 when unknown).
    var outputFrames: Int
    private let packetNanos: UInt64
    private var owed=0,run=0
    private var primed=false
    private var lastArrival: UInt64=0
    /// Frames of packets seen above the trim line in a row.
    private var above=0
    private(set) var skipped: UInt64=0
    private(set) var trimmed: UInt64=0

    enum Arrival: Equatable {
        /// Its time was already concealed.
        case skip
        /// Play it, after `lead` frames of silence.
        case play(lead: Int)
        /// Clock drift surplus: decode it, so the decoder goes on without a gap, but do not play it.
        /// The next packet fades in from its start.
        case trim
    }
    init(packetMs: Int,outputFrames: Int = 0) {
        packetFrames=48*max(1,packetMs)
        packetNanos=UInt64(max(1,packetMs))*1_000_000
        self.outputFrames=outputFrames
    }
    private var readFrames: Int { outputFrames > 0 ? outputFrames : Self.defaultReadFrames }
    /// Concealment starts once the ring holds less than the output's next read.
    var lowWater: Int { max(packetFrames,readFrames) }
    /// The ring's limit, the last resort: a read above the trim line, as Nightjar's queue limit.
    var ringLimit: Int { max(Self.minRingLimit,2*lead+2*packetFrames) }
    /// Silence led with on an empty queue.
    var lead: Int { 48*Self.leadMs+readFrames }
    /// A packet from the stream (`lost` for one the engine gave up on), with `queued` frames in
    /// the ring.
    mutating func packet(lost: Bool,queued: Int,nowNanos: UInt64) -> Arrival {
        lastArrival=nowNanos
        if owed > 0 { owed -= 1;skipped += 1;return .skip }
        guard !lost else { return .play(lead:0) }
        if drift(queued:queued) { run=0;trimmed += 1;return .trim }
        let lead=(!primed || queued == 0) ? self.lead : 0
        run=0;primed=true
        return .play(lead:lead)
    }
    private mutating func drift(queued: Int) -> Bool {
        guard queued > lead+packetFrames else { above=0;return false }
        above += packetFrames
        guard above >= 48*Self.trimAfterMs else { return false }
        above=0
        return true
    }
    /// Fades `pcm` in from `head` over the frames both have.
    static func crossfade(from head: [Float],into pcm: inout [Float],channels: Int) {
        let frames=min(head.count,pcm.count)/channels
        for index in 0..<frames*channels {
            let step=Float(index/channels)/Float(frames)
            pcm[index]=pcm[index]*step+head[index]*(1-step)
        }
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
    mutating func reset() { primed=false;owed=0;run=0;above=0 }
}
