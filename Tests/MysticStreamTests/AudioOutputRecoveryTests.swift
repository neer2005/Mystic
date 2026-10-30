import XCTest
import Foundation
import CMystic
import MysticKit
@testable import MysticStream

final class AudioOutputRecoveryTests: XCTestCase {
    private let info=AudioSetupInfo(channelCount:2,channelMask:3,packetDurationMs:5,samplesPerFrame:240)
    private func packets() throws -> [Data] {
        struct Fixture: Decodable { let packets: [Data] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"audio-stereo",withExtension:"json",subdirectory:"Fixtures"))
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)).packets
    }
    private func player(_ outputs: TestAudioOutputs,_ monitor: TestAudioOutputMonitor,
                        retryDelay: TimeInterval = 0.01,routeDelay: TimeInterval = 0.02) -> AudioPlayer {
        AudioPlayer(monitor:monitor,makeOutput:{ try outputs.make(gain:$0,changed:$1) },retryDelay:retryDelay,routeDelay:routeDelay)
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
        XCTAssertEqual(stats.queuedFrames,0);XCTAssertEqual(stats.discardedOutputFrames,140)
        XCTAssertEqual(second.initialGain,0)
        packets[1].withUnsafeBytes { player.play($0) }
        XCTAssertTrue(second.read(240).allSatisfy { $0 == 0 },"Mute must be effective from the first sample after a route change")
        player.setVolume(0.35,muted:false)
        packets[2].withUnsafeBytes { player.play($0) }
        XCTAssertTrue(second.read(240).contains { abs($0) > 0.001 })
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
private final class TestAudioOutputs: @unchecked Sendable {
    private let lock=NSLock()
    private var outputs: [TestAudioOutput] = []
    private var failureCount=0,count=0,name="Speakers",rate=48_000.0
    var failures: Int { get { lock.withLock { failureCount } } set { lock.withLock { failureCount=newValue } } }
    var attempts: Int { lock.withLock { count } }
    var all: [TestAudioOutput] { lock.withLock { outputs } }
    func route(name: String,rate: Double) { lock.withLock { self.name=name;self.rate=rate } }
    func make(gain: Float,changed: @escaping @Sendable () -> Void) throws -> TestAudioOutput {
        try lock.withLock {
            count += 1
            if failureCount > 0 { failureCount -= 1;throw AudioPlaybackError("Device unavailable") }
            let output=try TestAudioOutput(gain:gain,name:name,rate:rate,changed:changed)
            outputs.append(output);return output
        }
    }
}
private final class TestAudioOutput: AudioOutputPipeline,@unchecked Sendable {
    let render: AudioRenderState
    let device: AudioOutputDevice?
    let sampleRate: Double
    let initialGain: Float
    let changed: @Sendable () -> Void
    private let lock=NSLock();private var stopCount=0
    var stops: Int { lock.withLock { stopCount } }
    init(gain: Float,name: String,rate: Double,changed: @escaping @Sendable () -> Void) throws {
        render=try AudioRenderState(initialGain:gain);initialGain=gain
        device=AudioOutputDevice(id:1,name:name);sampleRate=rate;self.changed=changed
    }
    func stop() { lock.withLock { stopCount += 1 } }
    func read(_ frames: Int) -> [Float] {
        var left=Array(repeating:Float(0),count:frames),right=left
        _=left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            mystic_pcm_ring_read(render.ring,l.baseAddress,r.baseAddress,UInt32(frames))
        } }
        return (0..<frames).flatMap { [left[$0],right[$0]] }
    }
}
