import XCTest
import Foundation
import CMystic
import MysticKit
import MysticCore
@testable import MysticStream

final class AudioOutputRecoveryTests: XCTestCase {
    private let info=AudioSetupInfo(channelCount:2,channelMask:3,packetDurationMs:5,samplesPerFrame:240)
    private func packets(_ name: String = "stereo") throws -> [Data] {
        struct Fixture: Decodable { let packets: [Data] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"audio-"+name,withExtension:"json",subdirectory:"Fixtures"))
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)).packets
    }
    private func player(_ outputs: TestAudioOutputs,_ monitor: TestAudioOutputMonitor,
                        retryDelay: TimeInterval = 0.01,routeDelay: TimeInterval = 0.02) -> AudioPlayer {
        // No real-time concealment timer: these tests are about outputs, and a tick between their
        // steps on a busy machine would conceal and then skip the packets they read back.
        AudioPlayer(monitor:monitor,makeOutput:{ info,gain,reason,changed in try outputs.make(info:info,gain:gain,reason:reason,changed:changed) },
                    retryDelay:retryDelay,routeDelay:routeDelay,concealTimer:false)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return };try await Task.sleep(for:.milliseconds(5)) }
        XCTFail("Timed out waiting for audio output recovery")
    }
    func testRouteBurstCoalescesDiscardsOldAudioAndRetainsMuteAndStatistics() async throws {
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor(),player=player(outputs,monitor)
        try player.setup(info)
        XCTAssertEqual(outputs.attempts,0,"Setup validates Opus without requiring an output device")
        player.start();player.start()
        XCTAssertEqual(outputs.attempts,1)
        let packets=try packets(),first=try XCTUnwrap(outputs.all.first)
        try XCTUnwrap(packets.first).withUnsafeBytes { player.play($0) }
        _=first.read(100)
        let rendered=player.statistics.renderedFrames
        XCTAssertEqual(rendered,100)
        player.setVolume(0.35,muted:true)
        outputs.route(name:"Headphones",rate:44_100)
        for _ in 0..<100 { monitor.emit() }
        try await wait { outputs.all.count == 2 && player.statistics.outputStatus == .playing }
        let second=try XCTUnwrap(outputs.all.last),stats=player.statistics
        XCTAssertEqual(outputs.attempts,2)
        XCTAssertEqual(first.stops,1);XCTAssertEqual(stats.outputDevice,"Headphones")
        XCTAssertEqual(stats.outputSampleRate,44_100);XCTAssertEqual(stats.outputRestarts,1)
        XCTAssertEqual(stats.renderedFrames,rendered)
        // The first packet's lead (992 frames) and the packet, less the 100 read.
        XCTAssertEqual(stats.queuedFrames,0);XCTAssertEqual(stats.discardedOutputFrames,1132)
        XCTAssertEqual(second.initialGain,0)
        let lead=992
        packets[1].withUnsafeBytes { player.play($0) }
        XCTAssertTrue(second.read(lead+240).allSatisfy { $0 == 0 },"Mute must be effective from the first sample after a route change")
        player.setVolume(0.35,muted:false)
        packets[2].withUnsafeBytes { player.play($0) }
        XCTAssertTrue(second.read(lead+240).suffix(480).contains { abs($0) > 0.001 },"after the lead on the emptied queue")
        XCTAssertEqual(player.statistics.decodedPackets,3)
        player.cleanup()
    }
    func testUnavailableOutputKeepsDecoderStateAndRecoversOnLaterDeviceEvent() async throws {
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor(),player=player(outputs,monitor)
        outputs.failures=4
        try player.setup(info);player.start()
        try await wait { player.statistics.outputStatus == .unavailable }
        XCTAssertEqual(outputs.attempts,4)
        let packets=try packets(),reference=try OpusAudioDecoder(info)
        for packet in packets.prefix(5) {
            packet.withUnsafeBytes { player.play($0) }
            try packet.withUnsafeBytes { try reference.decode($0) { _,_ in } }
        }
        player.play(nil);try reference.decode(nil) { _,_ in }
        XCTAssertEqual(player.statistics.decodedPackets,5)
        XCTAssertEqual(player.statistics.concealedPackets,1)
        XCTAssertEqual(player.statistics.discardedOutputFrames,1440)
        outputs.route(name:"Speakers",rate:48_000);monitor.emit()
        try await wait { player.statistics.outputStatus == .playing }
        player.setVolume(1,muted:false)
        let output=try XCTUnwrap(outputs.all.last)
        packets[5].withUnsafeBytes { player.play($0) }
        var expected: [Float] = []
        try packets[5].withUnsafeBytes { try reference.decode($0) { samples,frames in expected=Array(samples.prefix(frames*2)) } }
        XCTAssertTrue(output.read(992).allSatisfy { $0 == 0 },"the first packet on the new output is led with silence")
        let actual=output.read(240)
        // The gain transition is complete after 128 frames. Remaining PCM must match
        // a continuously advanced decoder, not a restarted/frozen Opus state.
        for index in 256..<expected.count { XCTAssertEqual(actual[index],expected[index],accuracy:0.00001) }
        XCTAssertEqual(player.statistics.queuedFrames,0)
        player.cleanup()
    }
    func testManualRetryReopensUnavailableOutputButNeverStoppedPlayback() async throws {
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor(),player=player(outputs,monitor)
        outputs.failures=4
        try player.setup(info);player.start()
        try await wait { player.statistics.outputStatus == .unavailable }
        player.retryOutput()
        try await wait { player.statistics.outputStatus == .playing }
        XCTAssertEqual(outputs.attempts,5)
        player.stop();player.retryOutput();monitor.emit()
        try await Task.sleep(for:.milliseconds(40))
        XCTAssertEqual(outputs.attempts,5);XCTAssertEqual(player.statistics.outputStatus,.idle)
        XCTAssertTrue(monitor.isStopped)
        player.cleanup()
    }
    func testStopAndNewSetupFencePendingRetriesOldMonitorAndOldEngineCallbacks() async throws {
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor()
        let player=player(outputs,monitor,retryDelay:0.05,routeDelay:0.03)
        try player.setup(info);player.start()
        let first=try XCTUnwrap(outputs.all.first),oldMonitor=try XCTUnwrap(monitor.callback)
        outputs.failures=1
        first.changed()
        try await wait { outputs.attempts == 2 }
        player.stop()
        try player.setup(info);player.start()
        XCTAssertEqual(outputs.attempts,3)
        first.changed();oldMonitor()
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(outputs.attempts,3,"Old retries and both observer kinds must not rebuild a newer session")
        XCTAssertEqual(player.statistics.outputRestarts,0)
        XCTAssertEqual(player.statistics.outputStatus,.playing)
        player.cleanup()
    }
    func testEngineNotificationsRecoverWhenDeviceMonitoringCannotStart() async throws {
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor(),player=player(outputs,monitor)
        monitor.failStart=true
        try player.setup(info);player.start()
        let first=try XCTUnwrap(outputs.all.first)
        first.changed()
        try await wait { outputs.all.count == 2 }
        first.changed()
        try await Task.sleep(for:.milliseconds(35))
        XCTAssertEqual(outputs.attempts,2,"Retired engines cannot trigger more rebuilds")
        XCTAssertEqual(player.statistics.outputStatus,.playing)
        player.cleanup()
    }
    func testSurroundToHeadphonesAndBackRebuildsRoutingAndRetainsMute() async throws {
        let speakers: [AudioSpeaker]=[.left,.right,.center,.lfe,.surroundLeft,.surroundRight,.rearLeft,.rearRight]
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor(),player=player(outputs,monitor)
        let info=AudioSetupInfo(channelCount:8,channelMask:0x63F,packetDurationMs:5,samplesPerFrame:240,
            streams:8,coupledStreams:0,mapping:[0,1,2,3,4,5,6,7])
        outputs.route(name:"HDMI 7.1",rate:48_000,speakers:speakers)
        try player.setup(info);player.start()
        let packets=try packets("surround71"),first=try XCTUnwrap(outputs.all.first)
        XCTAssertEqual(player.statistics.outputLayout,"7.1 discrete");XCTAssertEqual(first.render.channels,8)
        packets[0].withUnsafeBytes { player.play($0) }
        player.setVolume(0.25,muted:true)
        outputs.route(name:"Headphones",rate:44_100);monitor.emit()
        try await wait { outputs.all.count == 2 && player.statistics.outputStatus == .playing }
        let headphones=try XCTUnwrap(outputs.all.last)
        XCTAssertEqual(headphones.render.channels,2);XCTAssertEqual(player.statistics.outputLayout,"7.1 → stereo")
        XCTAssertNotNil(player.statistics.stereoFallbackReason)
        packets[1].withUnsafeBytes { player.play($0) }
        XCTAssertTrue(headphones.read(240).allSatisfy { $0 == 0 })
        outputs.route(name:"HDMI 7.1",rate:96_000,speakers:speakers);monitor.emit()
        try await wait { outputs.all.count == 3 && player.statistics.outputStatus == .playing }
        let surround=try XCTUnwrap(outputs.all.last)
        XCTAssertEqual(surround.render.channels,8);XCTAssertNil(player.statistics.stereoFallbackReason)
        let lead=992
        packets[2].withUnsafeBytes { player.play($0) }
        XCTAssertTrue(surround.read(lead+240).allSatisfy { $0 == 0 })
        player.setVolume(0.25,muted:false)
        packets[3].withUnsafeBytes { player.play($0) }
        let audible=surround.read(lead+240)
        for channel in 0..<8 { XCTAssertTrue((lead+128..<lead+240).contains { abs(audible[$0*8+channel]) > 0.001 }) }
        first.changed();try await Task.sleep(for:.milliseconds(35))
        XCTAssertEqual(outputs.attempts,3);XCTAssertEqual(player.statistics.decodedPackets,4)
        XCTAssertEqual(player.statistics.decodeErrors,0)
        player.cleanup()
    }
    func testFailedSurroundGraphFallsBackAndItsLateCallbackCannotRestartPlayback() async throws {
        let outputs=TestAudioOutputs(),monitor=TestAudioOutputMonitor(),player=player(outputs,monitor)
        outputs.route(name:"Receiver",rate:48_000,speakers:AudioSpeaker.allCases)
        outputs.failures=1
        let info=AudioSetupInfo(channelCount:8,channelMask:0x63F,packetDurationMs:5,samplesPerFrame:240,
            streams:8,coupledStreams:0,mapping:[0,1,2,3,4,5,6,7])
        try player.setup(info);player.start()
        XCTAssertEqual(outputs.attempts,2)
        XCTAssertEqual(player.statistics.outputStatus,.playing)
        XCTAssertEqual(player.statistics.outputLayout,"7.1 → stereo")
        XCTAssertEqual(player.statistics.stereoFallbackReason,"Multichannel playback could not start on this output")
        try XCTUnwrap(outputs.allCallbacks.first)()
        try await Task.sleep(for:.milliseconds(40))
        XCTAssertEqual(outputs.attempts,2)
        monitor.emit()
        try await wait { outputs.attempts == 3 && player.statistics.outputLayout == "7.1 discrete" }
        player.cleanup()
    }
}

private final class TestAudioOutputMonitor: AudioOutputMonitoring,@unchecked Sendable {
    private let lock=NSLock()
    private var handler: (@Sendable () -> Void)?
    var failStart=false
    var callback: (@Sendable () -> Void)? { lock.withLock { handler } }
    var isStopped: Bool { callback == nil }
    func start(changed: @escaping @Sendable () -> Void) throws {
        if failStart { throw AudioPlaybackError("No monitor") }
        lock.withLock { handler=changed }
    }
    func refresh() throws {}
    func stop() { lock.withLock { handler=nil } }
    func emit() { callback?() }
}
final class AudioPlayoutTests: XCTestCase {
    private let ms: UInt64=1_000_000
    /// Nightjar's drift simulation: pairs of 5 ms packets every 10 ms, a device reading `read`
    /// frames with its clock `ppm` slow, on a 0.1 ms step.
    private func drift(seconds: UInt64,ppm: Double,read: Int,held: (Int) -> UInt64 = { _ in 0 }) -> (trims: UInt64,peak: Int) {
        var playout=AudioPlayout(packetMs:5,outputFrames:read)
        let end=seconds*1_000_000,period=Double(read)*1000/48*(1+ppm/1e6)
        var network: [UInt64]=[],head=0,queued=0,started=false,pair=0,peak=0
        var nextPair: UInt64=0,released: UInt64=0,at: UInt64=0,pulls=0.0
        while at < end {
            while nextPair <= at {
                released=max(released,nextPair+held(pair)*1000)
                network += [released,released];pair += 1;nextPair += 10_000
            }
            while head < network.count,network[head] <= at {
                head += 1
                switch playout.packet(lost:false,queued:queued,nowNanos:at*1000) {
                case .play(let lead): queued += lead+240;started=true
                case .trim,.skip: break
                }
            }
            if head > 4096 { network.removeFirst(head);head=0 }
            if started { queued += playout.tick(queued:queued,nowNanos:at*1000)*240 }
            if started,Double(at) >= pulls*period { pulls += 1;queued -= min(queued,read) }
            peak=max(peak,queued)
            at += 100
        }
        return (playout.trimmed,peak)
    }
    func testASlowDeviceClockIsTrimmedAPacketAtATimeBeforeTheRingsLimit() {
        for read in [512,1024] {
            for (seconds,ppm) in [(1200,35.0),(300,300.0)] as [(UInt64,Double)] {
                let run=drift(seconds:seconds,ppm:ppm,read:read)
                let surplus=UInt64(Double(seconds)*ppm/1e6*1000/5)
                XCTAssertGreaterThan(run.trims,0,"\(read), \(ppm) ppm")
                XCTAssertLessThanOrEqual(run.trims,surplus+1,"\(read), \(ppm) ppm")
                XCTAssertLessThan(run.peak,AudioPlayout(packetMs:5,outputFrames:read).ringLimit,"\(read), \(ppm) ppm: never reaches the ring's limit")
            }
        }
    }
    func testSteadyStateFastDevicesAndJitterBurstsAreNeverTrimmed() {
        let jitter: (Int) -> UInt64={ pair in pair%300 == 7 ? 30 : pair%50 == 3 ? 12 : 0 }
        for read in [512,1024] {
            for ppm in [0.0,-35.0,-300.0] {
                XCTAssertEqual(drift(seconds:300,ppm:ppm,read:read).trims,0,"\(read), \(ppm) ppm")
                // A fast device that runs dry in a burst is led again with the burst's packets on top:
                // real surplus, taken off 2 s later. Mystic's lead sits past a read, so this shows at
                // 300 ppm only.
                let bursts=drift(seconds:300,ppm:ppm,read:read,held:jitter).trims
                if ppm == -300 { XCTAssertLessThanOrEqual(bursts,8,"\(read), bursts") }
                else { XCTAssertEqual(bursts,0,"\(read), \(ppm) ppm, bursts") }
            }
        }
    }
    func testAPacketIsTrimmedOnlyAfterTwoSecondsAboveTheLine() {
        var playout=AudioPlayout(packetMs:5)
        let line=playout.lead+240
        XCTAssertEqual(playout.packet(lost:false,queued:0,nowNanos:0),.play(lead:992))
        for n in 1..<400 { XCTAssertEqual(playout.packet(lost:false,queued:line+1,nowNanos:UInt64(n)*5*ms),.play(lead:0)) }
        XCTAssertEqual(playout.packet(lost:false,queued:line+1,nowNanos:2000*ms),.trim)
        XCTAssertEqual(playout.trimmed,1)
        for n in 0..<399 { XCTAssertEqual(playout.packet(lost:false,queued:line+1,nowNanos:UInt64(2005+n*5)*ms),.play(lead:0)) }
        XCTAssertEqual(playout.packet(lost:false,queued:line,nowNanos:4000*ms),.play(lead:0),"at the line the count starts again")
        XCTAssertEqual(playout.packet(lost:false,queued:line+1,nowNanos:4005*ms),.play(lead:0))
    }
    func testTheLatePacketTimerTicksNoFasterThanA5MsOpusStream() {
        XCTAssertEqual(AudioPlayout.tickMs(packetMs:1),5,"7.1 PCM's 1 ms packets")
        XCTAssertEqual(AudioPlayout.tickMs(packetMs:2),5,"5.1 PCM's 2 ms packets")
        XCTAssertEqual(AudioPlayout.tickMs(packetMs:5),5)
        XCTAssertEqual(AudioPlayout.tickMs(packetMs:20),20)
        // One tick fills the whole shortfall, in whole 1 ms packets, so the slower tick still
        // tops the ring up past the next read, and those packets are skipped when they arrive.
        var playout=AudioPlayout(packetMs:1)
        XCTAssertEqual(playout.packet(lost:false,queued:0,nowNanos:0),.play(lead:992))
        let queued=400
        let packets=playout.tick(queued:queued,nowNanos:5*ms)
        XCTAssertEqual(packets,3)
        XCTAssertGreaterThanOrEqual(queued+packets*48,playout.lowWater)
        for n in 0..<3 { XCTAssertEqual(playout.packet(lost:false,queued:queued,nowNanos:UInt64(6+n)*ms),.skip) }
        XCTAssertEqual(playout.packet(lost:false,queued:queued,nowNanos:9*ms),.play(lead:0))
    }
    func testATrimmedPacketFadesIntoTheNextWithoutAClick() {
        let tone: (Int,Int) -> [Float]={ start,count in (start..<start+count).flatMap { i -> [Float] in
            let value=0.5*sin(2*Float.pi*440*Float(i)/48000);return [value,value] } }
        // Played up to frame 240; the packet at 240 is trimmed, and the next goes on from 480.
        var out=tone(0,240)
        let head=Array(tone(240,240).prefix(240*2))
        var next=tone(480,240)
        AudioPlayout.crossfade(from:head,into:&next,channels:2)
        out += next
        let natural=0.5*2*Float.pi*440/48000
        let left=stride(from:0,to:out.count,by:2).map { out[$0] }
        let worst=zip(left,left.dropFirst()).map { abs($1-$0) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst,natural*1.5)
    }
    func testAnEmptyQueueIsLedWithSilenceAndALatePacketConcealedOnlyBeforeTheOutputStarves() {
        var playout=AudioPlayout(packetMs:5)
        XCTAssertEqual(playout.lowWater,512,"the output's usual read")
        XCTAssertEqual(playout.lead,992,"Nightjar's 10 ms past one read")
        XCTAssertEqual(playout.tick(queued:0,nowNanos:50*ms),0,"nothing is concealed before the first packet")
        XCTAssertEqual(playout.packet(lost:false,queued:0,nowNanos:0),.play(lead:992))
        XCTAssertEqual(playout.tick(queued:100,nowNanos:4*ms),0,"not late yet")
        XCTAssertEqual(playout.tick(queued:600,nowNanos:6*ms),0,"late, but the next read is covered")
        XCTAssertEqual(playout.tick(queued:100,nowNanos:6*ms),2,"fills up to one read")
        XCTAssertEqual(playout.packet(lost:false,queued:580,nowNanos:7*ms),.skip)
        XCTAssertEqual(playout.packet(lost:true,queued:580,nowNanos:8*ms),.skip,"a packet the engine gave up on is owed too")
        XCTAssertEqual(playout.packet(lost:false,queued:300,nowNanos:9*ms),.play(lead:0),"a queue that holds audio needs no lead")
        XCTAssertEqual(playout.skipped,2)
        XCTAssertEqual(playout.packet(lost:false,queued:0,nowNanos:200*ms),.play(lead:992),"ran dry: led again")
    }
    func testConcealmentStopsAfterAHundredMillisecondsAndWhatFollowsIsNew() {
        var playout=AudioPlayout(packetMs:5)
        _=playout.packet(lost:false,queued:0,nowNanos:0)
        var concealed=0
        for step in 1...40 { concealed += playout.tick(queued:0,nowNanos:UInt64(step)*10*ms) }
        XCTAssertEqual(concealed,20,"100 ms of 5 ms packets")
        XCTAssertEqual(playout.packet(lost:false,queued:0,nowNanos:401*ms),.play(lead:992),"after the outage, packets are new, not late")
        XCTAssertEqual(playout.skipped,0)
        XCTAssertEqual(playout.tick(queued:0,nowNanos:410*ms),3,"a new packet starts a new allowance")
    }
    func testTheOutputsOwnReadSetsTheMarks() {
        var playout=AudioPlayout(packetMs:10,outputFrames:1024)
        XCTAssertEqual(playout.lowWater,1024);XCTAssertEqual(playout.lead,1504)
        _=playout.packet(lost:false,queued:0,nowNanos:0)
        XCTAssertEqual(playout.tick(queued:0,nowNanos:20*ms),3)
        playout.reset()
        XCTAssertEqual(playout.tick(queued:0,nowNanos:40*ms),0)
        XCTAssertEqual(playout.packet(lost:false,queued:0,nowNanos:41*ms),.play(lead:1504),"after a reset the queue is led again")
    }
    /// The case behind choppy audio on Wi-Fi: 5 ms packets arriving in order with a few ms of
    /// jitter, read 512 frames at a time. Concealing below 10 ms with no lead replaced about 12
    /// packets a second (6 %) with concealment and threw the real ones away.
    func testOrdinaryWiFiJitterIsNeverConcealed() {
        var playout=AudioPlayout(packetMs:5)
        var seed: UInt64=7
        func uniform() -> Double { seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Double(seed >> 11)/Double(1 << 53) }
        var arrivals: [Double]=[],previous=0.0
        for packet in 0..<12_000 {
            // About 3 ms of jitter, sum of uniforms for a bell shape, never out of order.
            let jitter=(uniform()+uniform()+uniform())*2
            previous=max(previous,Double(packet)*5+jitter);arrivals.append(previous)
        }
        enum Event { case packet,read,tick }
        var events: [(Double,Event)]=arrivals.map { ($0,.packet) }
        events+=stride(from:0.0,to:60_000,by:512.0/48).map { ($0,.read) }
        events+=stride(from:0.0,to:60_000,by:5.0).map { ($0,.tick) }
        events.sort { $0.0 < $1.0 }
        var queued=0,concealed=0,underrun=0
        for (at,event) in events {
            let now=UInt64(at*1_000_000)
            switch event {
            case .packet:
                if case let .play(lead)=playout.packet(lost:false,queued:queued,nowNanos:now) { queued=min(2880,queued+lead+240) }
            case .read: if queued < 512 { underrun+=512-queued;queued=0 } else { queued-=512 }
            case .tick: let n=playout.tick(queued:queued,nowNanos:now);concealed+=n;queued+=n*240
            }
        }
        XCTAssertEqual(concealed,0,"no real packet was replaced")
        XCTAssertEqual(underrun,512,"silent only for the read before the first packet arrived")
    }
}

final class AudioLatePacketTests: XCTestCase {
    func testThePlayerLeadsTheFirstPacketFillsALatePacketsTimeAndSkipsItOnArrival() throws {
        struct Fixture: Decodable { let packets: [Data] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"audio-stereo",withExtension:"json",subdirectory:"Fixtures"))
        let packets=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)).packets
        let clock=TestClock(),outputs=TestAudioOutputs()
        let player=AudioPlayer(monitor:TestAudioOutputMonitor(),makeOutput:{ info,gain,reason,changed in
            try outputs.make(info:info,gain:gain,reason:reason,changed:changed) },clock:{ clock.now },concealTimer:false)
        try player.setup(AudioSetupInfo(channelCount:2,channelMask:3,packetDurationMs:5,samplesPerFrame:240));player.start()
        let output=try XCTUnwrap(outputs.all.first)
        packets[0].withUnsafeBytes { player.play($0) }
        XCTAssertEqual(player.statistics.queuedFrames,992+240,"the first packet is led with silence")
        _=output.read(1032)
        clock.now=6_000_000
        player.concealLatePackets()
        XCTAssertEqual(player.statistics.concealedPackets,2)
        XCTAssertEqual(player.statistics.queuedFrames,680,"two packets' worth covered the next read")
        packets[1].withUnsafeBytes { player.play($0) };packets[2].withUnsafeBytes { player.play($0) }
        packets[3].withUnsafeBytes { player.play($0) }
        let stats=player.statistics
        XCTAssertEqual(stats.skippedLatePackets,2);XCTAssertEqual(stats.decodedPackets,2)
        XCTAssertEqual(stats.queuedFrames,920,"latency did not grow past the concealment and one packet")
        player.cleanup()
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock=NSLock();private var value: UInt64=0
    var now: UInt64 { get { lock.withLock { value } } set { lock.withLock { value=newValue } } }
}

private final class TestAudioOutputs: @unchecked Sendable {
    private let lock=NSLock()
    private var outputs: [TestAudioOutput] = []
    private var failureCount=0,count=0,name="Speakers",rate=48_000.0
    private var speakers: [AudioSpeaker]?
    private var callbacks: [@Sendable () -> Void] = []
    var allCallbacks: [@Sendable () -> Void] { lock.withLock { callbacks } }
    var failures: Int { get { lock.withLock { failureCount } } set { lock.withLock { failureCount=newValue } } }
    var attempts: Int { lock.withLock { count } }
    var all: [TestAudioOutput] { lock.withLock { outputs } }
    func route(name: String,rate: Double,speakers: [AudioSpeaker]? = nil) { lock.withLock { self.name=name;self.rate=rate;self.speakers=speakers } }
    func make(info: AudioSetupInfo,gain: Float,reason: String?,changed: @escaping @Sendable () -> Void) throws -> TestAudioOutput {
        try lock.withLock {
            count += 1
            callbacks.append(changed)
            if failureCount > 0 { failureCount -= 1;throw AudioPlaybackError("Device unavailable") }
            let routing=try AudioChannelRouting(channelCount:Int(info.channelCount),channelMask:info.channelMask,
                destination:reason == nil ? speakers : nil,fallbackReason:reason)
            let output=try TestAudioOutput(gain:gain,name:name,rate:rate,routing:routing,changed:changed)
            outputs.append(output);return output
        }
    }
}
private final class TestAudioOutput: AudioOutputPipeline,@unchecked Sendable {
    let routing: AudioChannelRouting
    let render: AudioRenderState
    let device: AudioOutputDevice?
    let sampleRate: Double
    let initialGain: Float
    let changed: @Sendable () -> Void
    private let lock=NSLock();private var stopCount=0
    var stops: Int { lock.withLock { stopCount } }
    init(gain: Float,name: String,rate: Double,routing: AudioChannelRouting,changed: @escaping @Sendable () -> Void) throws {
        self.routing=routing;render=try AudioRenderState(initialGain:gain,channels:routing.outputChannels);initialGain=gain
        device=AudioOutputDevice(id:1,name:name);sampleRate=rate;self.changed=changed
    }
    func stop() { lock.withLock { stopCount += 1 } }
    func read(_ frames: Int) -> [Float] {
        let count=routing.outputChannels
        let samples=UnsafeMutablePointer<Float>.allocate(capacity:frames*count)
        samples.initialize(repeating:0,count:frames*count)
        defer { samples.deallocate() }
        let planes: [UnsafeMutablePointer<Float>?]=(0..<count).map { samples.advanced(by:$0*frames) }
        _=planes.withUnsafeBufferPointer { mystic_pcm_ring_read_planar(render.ring,$0.baseAddress,UInt32(count),UInt32(frames)) }
        return (0..<frames).flatMap { frame in (0..<count).map { samples[$0*frames+frame] } }
    }
}
