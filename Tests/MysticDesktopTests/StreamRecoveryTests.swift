import XCTest
import Foundation
import MysticKit
import MysticCore
import MysticStream
@testable import MysticDesktop

@MainActor
final class StreamRecoveryTests: XCTestCase {
    func testReconnectKeepsOriginalOptionsAndIgnoresOldSessionCallbacks() async throws {
        let host=RecoveryHost(),sessions=RecoverySessions(),clock=RecoveryClock()
        let model=try await running(host,sessions,clock)
        model.processMediaSnapshot(picture())
        sessions.all[0].emit(.terminated(code:-100))
        try await wait { sessions.all.count == 2 && model.phase == .streaming }
        XCTAssertEqual(clock.delays,[1000])
        XCTAssertEqual(host.launches.count,2)
        XCTAssertTrue(host.launches[1].resumeOnly)
        XCTAssertEqual(host.launches[0].width,host.launches[1].width)
        XCTAssertEqual(host.launches[0].appID,host.launches[1].appID)
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
                try await wait { host.rates.count == 1 && model.bitrateStatus.contains("20 Mbps") }
                XCTAssertEqual(host.rates,[20000]);XCTAssertEqual(sessions.all[0].begun,1)
                host.rejectRate=true;sessions.all[0].nextRate=16000
                model.processMediaSnapshot(picture(2))
                try await wait { model.bitrateStatus.contains("stopped") }
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
    private func running(_ host: RecoveryHost,_ sessions: RecoverySessions,_ clock: RecoveryClock,
                         reconnect: Bool = true,adaptive: Bool = false) async throws -> ConnectionModel {
        let model=ConnectionModel(vault:RecoveryVault(),rememberHost:false,makeHost:{ _,_,_,_ in host })
        model.makeSession={ _,_ in sessions.make() }
        model.nowMillis={ clock.now }
        model.sleepForRecovery={ delay in clock.advance(delay);await Task.yield() }
        model.automaticReconnect=reconnect;model.adaptiveBitrate=adaptive
        await model.prepare()
        guard model.capabilities?.supportedFormats ?? 0 != 0 else { throw XCTSkip("No hardware video decoder") }
        model.address="127.0.0.1";model.connect()
        try await wait { model.phase == .ready }
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
    var nextRate:UInt32? { get { lock.withLock { rate } } set { lock.withLock { rate=newValue } } }
    var stops:Int { lock.withLock { stopCount } }
    var begun:Int { lock.withLock { beginCount } }
    func emit(_ value:EngineEvent) { lock.withLock { event }?(value) }
    func start(host:String,launch:LaunchedStream,configuration:StreamConfiguration,decoder:VideoToolboxDecoder,audio:AudioPlayer,
               event:@escaping @Sendable (EngineEvent)->Void,failure:@escaping @Sendable (StreamStartFailure)->Void,
               microphoneMuted:Bool,microphoneStatus:@escaping @Sendable (String)->Void) {
        lock.withLock { self.event=event }
        if let startup { failure(startup) } else { event(.connected) }
    }
    func stop(completion:@escaping @Sendable ()->Void) { lock.withLock { stopCount+=1 };completion() }
    func requestVideoRecovery() {}
    func setMicrophoneMuted(_ muted:Bool) {}
    func send(_ event:RemoteInputEvent)->Bool { true }
    func beginAdaptiveBitrate(ceiling:UInt32,current:UInt32) async -> Bool { lock.withLock { beginCount+=1 };return true }
    func suggestedBitrate(decodeMillis:Float) async -> UInt32? { lock.withLock { let r=rate;rate=nil;return r } }
    func appliedBitrate(requested:UInt32,applied:UInt32) async {}
}
private final class RecoveryHost: HostService,@unchecked Sendable {
    private let lock=NSLock();private var currentApp:Int32=1,hostID="host1"
    private var options:[LaunchOptions]=[],requests:[UInt32]=[]
    private var infoFailure:Bool?
    func failNextInfo(retryable:Bool) { lock.withLock { infoFailure=retryable } }
    // Tests set these before a request starts; access from the main actor's async calls only.
    var supportsBitrate=true,rejectRate=false
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
