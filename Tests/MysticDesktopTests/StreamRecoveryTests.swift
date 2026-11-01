import XCTest
import Foundation
import MysticKit
import MysticCore
import MysticStream
@testable import MysticDesktop

@MainActor
final class StreamRecoveryTests: XCTestCase {
    func testConnectedStreamsAppearInHomeRecentPlay() async throws {
        let model=try await running(RecoveryHost(),RecoverySessions(),RecoveryClock())
        XCTAssertNotNil(model.home.games.first?.lastPlayed)
        model.disconnect()
        XCTAssertNotNil(model.home.games.first?.lastPlayed,"Recent history survives disconnect")
    }
    func testManualHTTPBitratePausesAutomaticControlAndKeepsSavedProfile() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock,adaptive:true)
        model.processMediaSnapshot(picture());try await wait { sessions.all[0].begun == 1 }
        let profile=model.effectiveVideoSettings
        await model.rates.change(kbps:40_000,fpsMilliHz:0,context:model.contextID)
        XCTAssertEqual(model.rates.appliedKbps,40_000)
        let count=host.rates.count
        sessions.all[0].nextRate=8_000;model.processMediaSnapshot(picture(2))
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(host.rates.count,count)
        XCTAssertEqual(model.effectiveVideoSettings,profile)
        await model.rates.change(kbps:30_000,fpsMilliHz:60_000,context:model.contextID)
        XCTAssertEqual(host.rates.count,count,"Bitrate-only hosts cannot receive frame-rate writes")
        sessions.all[0].emit(.terminated(code:-100))
        try await wait { sessions.all.count == 2 && model.phase == .streaming }
        XCTAssertNil(model.rates.appliedKbps)
        XCTAssertEqual(sessions.all[1].configuration?.bitrateKbps,Int32(profile.bitrateMbps)*1000)
        model.disconnect()
    }
    func testHealthTrialStartsFromTheLiveBitrateAndReportsRefusals() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock)
        let session=sessions.all[0]
        session.offer="none";await model.health.refreshReport()
        await model.health.runTrial(undo:false)
        XCTAssertTrue(host.rates.isEmpty,"No trial without the report's offer")
        session.offer="try";await model.health.refreshReport()
        XCTAssertEqual(model.health.report?.offer,.tryLower)
        host.liveKbps=20_000
        await model.health.runTrial(undo:false)
        XCTAssertEqual(host.rates,[16_000],"20 % below the encoder's live rate, not the saved one")
        XCTAssertEqual(session.trialSteps,[16_000])
        XCTAssertEqual(model.rates.appliedKbps,16_000)
        XCTAssertEqual(model.health.trialMessage,"Host applied 16.0 Mbps.")
        session.refusal = .minimum
        await model.health.runTrial(undo:false)
        XCTAssertEqual(host.rates,[16_000])
        XCTAssertEqual(model.health.trialMessage,"The encoder is already at the minimum trial bitrate. No change was made.")
        host.liveRuntime=false;session.refusal=nil
        await model.health.runTrial(undo:false)
        XCTAssertEqual(model.health.trialMessage,"This host does not allow bitrate changes during a stream.")
        model.disconnect()
        XCTAssertNil(model.health.report,"A new connection starts without the old report")
    }
    func testNegotiatedRatesUseHostReadbackAndIgnoreOldConnection() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock) { $0.fps=120 }
        sessions.all[0].setLive(supported:true,fail:false)
        await model.rates.refresh();XCTAssertTrue(model.rates.liveAvailable)
        let context=model.contextID
        await model.rates.change(kbps:40_000,fpsMilliHz:60_000,context:context)
        XCTAssertEqual(model.rates.appliedKbps,30_000)
        XCTAssertEqual(model.rates.appliedFPS,59_940)
        XCTAssertTrue(model.rates.message.contains("limited"))
        XCTAssertFalse(model.rates.busy)
        await model.rates.change(kbps:40_000,fpsMilliHz:121_000,context:context)
        XCTAssertEqual(sessions.all[0].liveWrites,1,"Do not exceed the launch frame-rate ceiling")
        sessions.all[0].setLive(supported:true,fail:true)
        await model.rates.change(kbps:35_000,fpsMilliHz:60_000,context:context)
        XCTAssertNil(model.rates.appliedKbps);XCTAssertFalse(model.rates.busy)
        model.disconnect()
        await model.rates.change(kbps:35_000,fpsMilliHz:60_000,context:context)
        XCTAssertEqual(sessions.all[0].liveWrites,2)
        XCTAssertNil(model.rates.appliedFPS)
    }
    func testReconnectKeepsResolvedGameProfileWhenStoredProfilesAndGlobalsChange() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock) { model in
            model.gameVideoSource = .custom
            var video=model.effectiveVideoSettings
            video.resolution="2560x1440";video.fps=120;video.bitrateMbps=55
            video.codec="h264";video.framePacing = .balanced;video.adaptiveBitrate=true
            model.updateGameVideo(video)
        }
        let original=try XCTUnwrap(sessions.all[0].configuration)
        XCTAssertEqual(original.width,2560);XCTAssertEqual(original.height,1440)
        XCTAssertEqual(original.fps,120);XCTAssertEqual(original.bitrateKbps,55_000)
        XCTAssertEqual(original.supportedVideoFormats & ~UInt32(0xF),0)
        XCTAssertEqual(model.presenter?.pacingMode,.balanced)
        let key=try XCTUnwrap(model.hostProfileKey),game=try XCTUnwrap(model.gameProfileKey)
        // Another settings writer may update persistence while a stream is active.
        model.profiles.update { try $0.setGame(source:.global,video:nil,host:key,game:game) }
        model.settings.update { $0.resolution="1280x720";$0.fps=60;$0.bitrateMbps=10;$0.framePacing="lowLatency";$0.adaptiveBitrate=false }
        // User-facing setters reject edits while a session is active.
        model.gameVideoSource = .custom
        XCTAssertEqual(model.gameVideoSource,.global)
        model.updateHostVideo(StreamVideoSettings(),hostKey:key)
        XCTAssertNil(model.profiles.value.hostVideo(for:key))
        model.processMediaSnapshot(picture())
        try await wait { sessions.all[0].begun == 1 }
        sessions.all[0].emit(.terminated(code:-100))
        try await wait { sessions.all.count == 2 && model.phase == .streaming }
        let resumed=try XCTUnwrap(sessions.all[1].configuration)
        XCTAssertEqual(resumed.width,original.width);XCTAssertEqual(resumed.height,original.height)
        XCTAssertEqual(resumed.fps,original.fps);XCTAssertEqual(resumed.bitrateKbps,original.bitrateKbps)
        XCTAssertEqual(resumed.supportedVideoFormats,original.supportedVideoFormats)
        XCTAssertEqual(resumed.colorSpace,original.colorSpace)
        XCTAssertEqual(model.presenter?.pacingMode,.balanced)
        XCTAssertTrue(host.launches[1].resumeOnly)
        model.processMediaSnapshot(picture());try await wait { sessions.all[1].begun == 1 }
        model.disconnect()
    }
    func testReconnectKeepsOriginalOptionsAndIgnoresOldSessionCallbacks() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock,pacing:.balanced)
        XCTAssertEqual(model.presenter?.pacingMode,.balanced)
        model.framePacing = .lowLatency
        model.processMediaSnapshot(picture())
        sessions.all[0].emit(.terminated(code:-100))
        try await wait { sessions.all.count == 2 && model.phase == .streaming }
        XCTAssertEqual(clock.delays,[1000])
        XCTAssertEqual(host.launches.count,2)
        XCTAssertTrue(host.launches[1].resumeOnly)
        XCTAssertEqual(host.launches[0].width,host.launches[1].width)
        XCTAssertEqual(host.launches[0].appID,host.launches[1].appID)
        XCTAssertEqual(model.presenter?.pacingMode,.balanced,"Recovery keeps the original presentation mode")
        XCTAssertEqual(sessions.all[0].stops,1)
        sessions.all[0].emit(.terminated(code:0))
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(model.phase,.streaming)
        model.disconnect()
    }
    func testNoRecoveryBeforeFirstPictureOrAfterCleanOrProtectedTermination() async throws {
        for code: Int32 in [-100,0,-103,-104] {
            let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
            let model=try await running(host,sessions,clock)
            if code != -100 { model.processMediaSnapshot(picture()) }
            sessions.all[0].emit(.terminated(code:code))
            try await wait { model.phase == .idle }
            XCTAssertTrue(clock.delays.isEmpty)
            XCTAssertEqual(host.launches.count,1)
        }
    }
    func testRecoveryChainExhaustsBudgetEvenWhenNewAttemptHasNoPicture() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock)
        model.processMediaSnapshot(picture())
        for attempt in 1...5 {
            sessions.all.last!.emit(.terminated(code:-100))
            try await wait { sessions.all.count == attempt+1 && model.phase == .streaming }
        }
        sessions.all.last!.emit(.terminated(code:-100))
        try await wait { model.phase == .idle }
        XCTAssertEqual(clock.delays,[1000,2000,4000,8000,12000])
        XCTAssertTrue(model.errorMessage?.contains("retry limit") == true)
    }
    func testDisconnectCancelsPendingRecovery() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock)
        model.sleepForRecovery={ _ in try await Task.sleep(for:.seconds(30)) }
        model.processMediaSnapshot(picture());sessions.all[0].emit(.terminated(code:-100))
        try await wait { model.phase == .reconnecting }
        model.disconnect()
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(model.phase,.idle)
        XCTAssertEqual(host.launches.count,1)
    }
    func testRecoveryRefusesChangedAppOrHostAndRespectsOptOut() async throws {
        for scenario in 0..<3 {
            let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
            let model=try await running(host,sessions,clock,reconnect:scenario != 2)
            if scenario == 0 { host.changeApp(2) }
            if scenario == 1 { host.changeID("other-host") }
            model.processMediaSnapshot(picture());sessions.all[0].emit(.terminated(code:-100))
            try await wait { model.phase == .idle }
            XCTAssertEqual(host.launches.count,1)
            XCTAssertNotNil(model.errorMessage)
            if scenario == 2 { XCTAssertTrue(clock.delays.isEmpty) }
        }
    }
    func testAutomaticBitrateIsOptInCapabilityGatedAndStopsOnHostFailure() async throws {
        for scenario in 0..<3 {
            let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
            host.supportsBitrate=scenario != 1
            let model=try await running(host,sessions,clock,adaptive:scenario != 0)
            model.processMediaSnapshot(picture())
            if scenario < 2 {
                try await Task.sleep(for:.milliseconds(20));XCTAssertTrue(host.rates.isEmpty)
            } else {
                try await wait { host.rates.count == 1 && model.rates.status.contains("20 Mbps") }
                XCTAssertEqual(host.rates,[20000]);XCTAssertEqual(sessions.all[0].begun,1)
                host.rejectRate=true;sessions.all[0].nextRate=16000
                model.processMediaSnapshot(picture(2))
                try await wait { model.rates.status.contains("stopped") }
                XCTAssertEqual(host.rates,[20000,16000])
                XCTAssertEqual(model.phase,.streaming)
                sessions.all[0].nextRate=12000;model.processMediaSnapshot(picture(3))
                try await Task.sleep(for:.milliseconds(20));XCTAssertEqual(host.rates.count,2)
            }
            model.disconnect()
        }
    }
    func testTransportFailureDuringRecoveryRetriesButHostRefusalDoesNot() async throws {
        for retryable in [true,false] {
            let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
            let model=try await running(host,sessions,clock)
            host.failNextInfo(retryable:retryable)
            model.processMediaSnapshot(picture());sessions.all[0].emit(.terminated(code:-100))
            if retryable {
                try await wait { sessions.all.count == 2 && model.phase == .streaming }
                XCTAssertEqual(clock.delays,[1000,2000])
            } else {
                try await wait { model.phase == .idle }
                XCTAssertEqual(host.launches.count,1)
            }
            model.disconnect()
        }
    }
    func testExpiredRecoveryNeverLaunchesAgain() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock)
        model.sleepForRecovery={ _ in clock.advance(60000) }
        model.processMediaSnapshot(picture());sessions.all[0].emit(.terminated(code:-100))
        try await wait { model.phase == .idle }
        XCTAssertEqual(host.launches.count,1)
        XCTAssertTrue(model.errorMessage?.contains("expired") == true)
    }
    func testStartupTransportFailureKeepsRetryChainButDecoderFailureStopsIt() async throws {
        for stage: Stage in [.rtspHandshake,.videoStreamStart] {
            let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
            let model=try await running(host,sessions,clock)
            sessions.failNextStartup(stage:stage,code:60)
            model.processMediaSnapshot(picture());sessions.all[0].emit(.terminated(code:-100))
            if stage == .rtspHandshake {
                try await wait { sessions.all.count == 3 && model.phase == .streaming }
                XCTAssertEqual(clock.delays,[1000,2000])
            } else {
                try await wait { model.phase == .idle }
                XCTAssertEqual(host.launches.count,2)
            }
            model.disconnect()
        }
    }
    func testVPNRoutesStreamAsRemoteWithSmallPacketsAndRoamingFollowsTheWatcher() async throws {
        let sessions=RecoverySessions()
        let model=try await running(RecoveryHost(),sessions,RecoveryClock(),configure:{ model in
            model.lookUpRoute={ _,_ in NetworkRoute.Report(route:nil,vpn:true,interface:"utun4") }
            model.startNetworkWatch={ _,_,_ in nil }
        })
        let config=try XCTUnwrap(sessions.all[0].configuration)
        XCTAssertEqual(config.location,.remote);XCTAssertEqual(config.packetSize,1024)
        XCTAssertTrue(config.clientRoaming,"roaming is on by default, as Nightjar")
        XCTAssertFalse(config.networkHints,"no watcher, so no hints and the engine's roaming stays off")
        model.disconnect()
        let lan=RecoverySessions(),events=WatchEvents()
        let other=try await running(RecoveryHost(),lan,RecoveryClock(),configure:{ model in
            model.clientRoaming=false;model.startNetworkWatch=events.start
        })
        let plain=try XCTUnwrap(lan.all[0].configuration)
        XCTAssertEqual(plain.location,.automatic);XCTAssertEqual(plain.packetSize,1392)
        XCTAssertFalse(plain.clientRoaming)
        other.disconnect()
    }
    func testANetworkBackOnANewAddressReconnectsAtOnceOnlyWhenTheStreamCannotContinue() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock(),events=WatchEvents()
        let model=try await running(host,sessions,clock,configure:{ $0.startNetworkWatch=events.start })
        XCTAssertTrue(try XCTUnwrap(sessions.all[0].configuration).networkHints)
        model.processMediaSnapshot(picture())
        // The same address back: the stream carries on and nothing reconnects.
        events.send(.lost);try await wait { model.status.hasPrefix("Network lost") }
        events.send(.changed(metered:false,afterLoss:true))
        try await wait { sessions.all[0].networkChanges == [false] }
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(sessions.all.count,1);XCTAssertTrue(model.status.hasPrefix("Streaming"))
        // A change without a loss goes to the session for roaming, nothing more.
        sessions.all[0].change = .cannotContinue
        events.send(.changed(metered:true,afterLoss:false))
        try await wait { sessions.all[0].networkChanges == [false,true] }
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(sessions.all.count,1)
        // Back on an address the stream cannot continue over: reconnect now, without the delay.
        events.send(.lost);events.send(.changed(metered:false,afterLoss:true))
        try await wait { sessions.all.count == 2 && model.phase == .streaming }
        XCTAssertEqual(clock.delays,[0])
        model.disconnect()
    }
    func testAMeteredReturnWithoutPermissionWaitsForTheConnectionsTimeout() async throws {
        let sessions=RecoverySessions(),events=WatchEvents()
        let model=try await running(RecoveryHost(),sessions,RecoveryClock(),configure:{ $0.startNetworkWatch=events.start })
        model.processMediaSnapshot(picture())
        sessions.all[0].change = .cannotContinue
        events.send(.lost);events.send(.changed(metered:true,afterLoss:true))
        try await wait { sessions.all[0].networkChanges == [true] }
        try await Task.sleep(for:.milliseconds(30))
        XCTAssertEqual(sessions.all.count,1)
        model.disconnect()
    }
    func testDisplayHeadroomGoesToTheLaunchAndOncePerScreenToTheHost() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions()
        let model=try await running(host,sessions,RecoveryClock(),configure:{ $0.launchHeadroom={ 3.5 } })
        XCTAssertEqual(host.launches.last?.displayHeadroom,3.5)
        XCTAssertEqual(sessions.all[0].displayReports,[],"no screen until a view shows the stream")
        let presenter=try XCTUnwrap(model.presenter)
        presenter.updateDisplay(name:"Studio Display",currentHeadroom:1,potentialHeadroom:2.5)
        try await wait { sessions.all[0].displayReports == [2.5] }
        // Brightness changes the headroom; the host keeps the first value for that screen.
        presenter.updateDisplay(name:"Studio Display",currentHeadroom:1,potentialHeadroom:6)
        presenter.updateDisplay(name:"Built-in Display",currentHeadroom:1,potentialHeadroom:8)
        try await wait { sessions.all[0].displayReports == [2.5,2.5,8] }
        model.processMediaSnapshot(picture())
        sessions.all[0].emit(.terminated(code:-100))
        try await wait { sessions.all.count == 2 && model.phase == .streaming }
        try XCTUnwrap(model.presenter).updateDisplay(name:"Built-in Display",currentHeadroom:1,potentialHeadroom:3)
        try await wait { sessions.all[1].displayReports == [8] }
        model.disconnect()
    }
    private func running(_ host: RecoveryHost,_ sessions: RecoverySessions,_ clock: RecoveryClock,
                         reconnect: Bool = true,adaptive: Bool = false,pacing: FramePacingMode = .lowLatency,
                         configure: (ConnectionModel) -> Void = { _ in }) async throws -> ConnectionModel {
        let model=ConnectionModel(vault:RecoveryVault(),rememberHost:false,makeHost:{ _,_,_,_ in host })
        model.makeSession={ _,_ in sessions.make() }
        model.nowMillis={ clock.now }
        model.sleepForRecovery={ delay in clock.advance(delay);await Task.yield() }
        model.automaticReconnect=reconnect;model.adaptiveBitrate=adaptive;model.framePacing=pacing
        await model.prepare()
        guard model.capabilities?.supportedFormats ?? 0 != 0 else { throw XCTSkip("No hardware video decoder") }
        model.address="127.0.0.1";model.connect()
        try await wait { model.phase == .ready }
        configure(model)
        model.play();try await wait { model.phase == .streaming }
        return model
    }
    private func picture(_ count: Int = 1) -> VideoTelemetrySnapshot {
        var telemetry=VideoTelemetryAccumulator()
        for _ in 0..<count { telemetry.decode(startMicros:1000,endMicros:3000) }
        return telemetry.snapshot(nowMicros:10000)
    }
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<400 { if done() { return };try await Task.sleep(for:.milliseconds(5)) }
        XCTFail("Timed out waiting for stream state")
    }
}
/// Stands in for the network watcher: keeps its event handler and starts no real watcher.
/// A nil watcher would mean "no route", so it hands back a watcher on loopback.
private final class WatchEvents: @unchecked Sendable {
    private let lock=NSLock();private var handler:(@Sendable (LinkEvent)->Void)?
    var start: @Sendable (String,UInt16,@escaping @Sendable (LinkEvent)->Void) async -> NetworkWatch? {
        { [self] _,_,onEvent in
            lock.withLock { handler=onEvent }
            let watch=NetworkWatch.start(host:"127.0.0.1",port:9) { _ in }
            return watch
        }
    }
    func send(_ event:LinkEvent) { lock.withLock { handler }?(event) }
}
private final class RecoveryClock: @unchecked Sendable {
    private let lock=NSLock();private var time: UInt64=1000;private var waits:[UInt64]=[]
    var now: UInt64 { lock.withLock { time } }
    var delays: [UInt64] { lock.withLock { waits } }
    func advance(_ delay: UInt64) { lock.withLock { time+=delay;waits.append(delay) } }
}
private final class RecoverySessions: @unchecked Sendable {
    private let lock=NSLock();private var values:[RecoverySession]=[];private var failure:StreamStartFailure?
    func failNextStartup(stage:Stage,code:Int32) { lock.withLock { failure=StreamStartFailure(message:"Start failed",stage:stage,code:code) } }
    var all:[RecoverySession] { lock.withLock { values } }
    func make() -> RecoverySession { lock.withLock { let s=RecoverySession(startup:failure);failure=nil;values.append(s);return s } }
}
private final class RecoverySession: StreamSessionService, @unchecked Sendable {
    private let startup:StreamStartFailure?
    init(startup:StreamStartFailure?) { self.startup=startup }
    private let lock=NSLock();private var event:(@Sendable (EngineEvent)->Void)?
    private var stopCount=0,beginCount=0;private var rate:UInt32?
    private var storedConfiguration:StreamConfiguration?
    var configuration:StreamConfiguration? { lock.withLock { storedConfiguration } }
    var nextRate:UInt32? { get { lock.withLock { rate } } set { lock.withLock { rate=newValue } } }
    var stops:Int { lock.withLock { stopCount } }
    var begun:Int { lock.withLock { beginCount } }
    func emit(_ value:EngineEvent) { lock.withLock { event }?(value) }
    func start(host:String,launch:LaunchedStream,configuration:StreamConfiguration,decoder:VideoToolboxDecoder,audio:AudioPlayer,
               event:@escaping @Sendable (EngineEvent)->Void,failure:@escaping @Sendable (StreamStartFailure)->Void,
               microphoneMuted:Bool,microphoneStatus:@escaping @Sendable (String)->Void) {
        lock.withLock { self.event=event;self.storedConfiguration=configuration }
        if let startup { failure(startup) } else { event(.connected) }
    }
    func stop(completion:@escaping @Sendable ()->Void) { lock.withLock { stopCount+=1 };completion() }
    private var liveSupported=false,liveFailure=false,liveCount=0
    var liveWrites:Int { lock.withLock { liveCount } }
    func setLive(supported:Bool,fail:Bool) { lock.withLock { liveSupported=supported;liveFailure=fail } }
    func liveRates(kbps:UInt32,fpsMilliHz:UInt32) async throws -> LiveRates {
        let (supported,fail)=lock.withLock { if kbps != 0 || fpsMilliHz != 0 { liveCount += 1 };return (liveSupported,liveFailure) }
        if fail { throw HostConnectionError("Host answer timed out") }
        if !supported { throw HostConnectionError("Unavailable") }
        if kbps == 0 && fpsMilliHz == 0 { return try recoveryDecode(#"{"available":true,"pending":false,"result":null,"error":null}"#) }
        return try recoveryDecode(#"{"available":true,"pending":false,"result":{"kbps":30000,"fpsMilliHz":59940,"bitrateStatus":2,"bitrateReason":4,"fpsStatus":2,"fpsReason":5},"error":null}"#)
    }
    func takeControllerFeedback() async -> [ControllerFeedback] { [] }
    private var networkResults:[Bool]=[]
    private var nextChange:NetworkChange = .carriesOn
    var networkChanges:[Bool] { lock.withLock { networkResults } }
    var change:NetworkChange { get { lock.withLock { nextChange } } set { lock.withLock { nextChange=newValue } } }
    func networkChanged(metered:Bool) async -> NetworkChange? { lock.withLock { networkResults.append(metered);return nextChange } }
    private var reports:[Float]=[]
    var displayReports:[Float] { lock.withLock { reports } }
    func reportDisplay(headroom:Float) async -> DisplayReport { lock.withLock { reports.append(headroom) };return .sent }
    func requestVideoRecovery() {}
    func setMicrophoneMuted(_ muted:Bool) {}
    func send(_ event:RemoteInputEvent)->Bool { true }
    func beginAdaptiveBitrate(ceiling:UInt32,current:UInt32) async -> Bool { lock.withLock { beginCount+=1 };return true }
    func suggestedBitrate(decodeMillis:Float) async -> UInt32? { lock.withLock { let r=rate;rate=nil;return r } }
    func appliedBitrate(requested:UInt32,applied:UInt32) async {}
    private var reportOffer="none",trialRefusal:TrialRefusal?,steps:[UInt32]=[]
    var offer:String { get { lock.withLock { reportOffer } } set { lock.withLock { reportOffer=newValue } } }
    var refusal:TrialRefusal? { get { lock.withLock { trialRefusal } } set { lock.withLock { trialRefusal=newValue } } }
    var trialSteps:[UInt32] { lock.withLock { steps } }
    func healthReport(currentKbps:UInt32,runtimeBitrate:Bool,automatic:Bool,busy:Bool) async -> StreamHealthReport? {
        try? recoveryDecode(#"{"findings":["NETWORK"],"samples":5,"recent":true,"worstLossPercent":6,"worstDecodeMs":2,"worstHostP95Ms":-1,"worstDisplayP95Ms":-1,"stalls":0,"stallPeriodMs":0,"hostIncludesSend":false,"lateSamples":0,"offer":"\#(offer)"}"#)
    }
    func trialBegin(undo:Bool,liveKbps:UInt32) async -> Result<UInt32,TrialRefusal> {
        if let refusal { return .failure(refusal) }
        return .success(liveKbps*4/5)
    }
    func trialApplied(undo:Bool,previousKbps:UInt32,appliedKbps:UInt32) async { lock.withLock { steps.append(appliedKbps) } }
}
private final class RecoveryHost: HostService,@unchecked Sendable {
    private let lock=NSLock();private var currentApp:Int32=1,hostID="host1"
    private var options:[LaunchOptions]=[],requests:[UInt32]=[]
    private var infoFailure:Bool?
    func failNextInfo(retryable:Bool) { lock.withLock { infoFailure=retryable } }
    // Tests set these before a request starts; access from the main actor's async calls only.
    var supportsBitrate=true,rejectRate=false
    var liveKbps:UInt32=0,liveRuntime=true
    func liveBitrate() async throws -> LiveBitrate { LiveBitrate(runtime:liveRuntime,kbps:liveKbps) }
    var launches:[LaunchOptions] { lock.withLock { options } }
    var rates:[UInt32] { lock.withLock { requests } }
    func changeApp(_ id:Int32) { lock.withLock { currentApp=id } }
    func changeID(_ id:String) { lock.withLock { hostID=id } }
    func serverInfo() async throws -> HostInfo {
        let failure=lock.withLock { let value=infoFailure;infoFailure=nil;return value }
        if let failure { throw HostConnectionError("Connection check failed",retryable:failure) }
        let (id,app)=lock.withLock { (hostID,currentApp) }
        return try recoveryDecode("{\"name\":\"PC\",\"uniqueID\":\"\(id)\",\"paired\":true,\"appVersion\":\"7.1.431.-1\",\"codecSupport\":1,\"currentGame\":\(app)}")
    }
    func apps() async throws -> [HostApp] { try recoveryDecode("[{\"id\":1,\"name\":\"Desktop\",\"uuid\":\"app1\",\"hdrSupported\":false}]") }
    func pair(pin:String) async throws -> PairedHost { throw HostConnectionError("not used") }
    func launch(_ value:LaunchOptions) async throws -> LaunchedStream {
        lock.withLock { options.append(value) }
        return try recoveryDecode("{\"rtspURL\":null,\"appVersion\":\"7.1.431.-1\",\"codecSupport\":1,\"key\":[],\"iv\":[],\"runtimeBitrate\":\(supportsBitrate)}")
    }
    func setBitrate(kbps:UInt32) async throws -> UInt32 {
        lock.withLock { requests.append(kbps) }
        if rejectRate { throw HostConnectionError("Host refused bitrate") }
        return kbps
    }
    func cancel() {}
}
private final class RecoveryVault: CredentialsStorage,@unchecked Sendable {
    func identity() throws -> ClientIdentity { try recoveryDecode("{\"uniqueID\":\"client\",\"certificate\":\"cert\",\"privateKey\":\"key\"}") }
    func certificate(for endpoint:String) throws -> String? { "pinned" }
    func saveCertificate(_ certificate:String,for endpoint:String) throws {}
}
private func recoveryDecode<T:Decodable>(_ json:String) throws -> T { try JSONDecoder().decode(T.self,from:Data(json.utf8)) }
