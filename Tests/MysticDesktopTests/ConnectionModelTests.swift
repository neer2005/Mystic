import XCTest
import Foundation
import MysticKit
import MysticCore
@testable import MysticDesktop

@MainActor
final class ConnectionModelTests: XCTestCase {
    func testProfileUsesAppUUIDAcrossRenamesAndNumericIDChanges() async throws {
        let profiles=StreamProfilesStore(storage:nil)
        let uuid="A1E7EF18-8053-415D-9C28-7BC441CB6298"
        let first=MockHost(paired:true,singleAppID:1,singleAppUUID:uuid,singleAppName:"Original")
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,profiles:profiles,makeHost:{ _,_,_,_ in first })
        model.address="pc.local";model.connect();try await settle(model)
        model.gameVideoSource = .custom
        var video=model.effectiveVideoSettings;video.bitrateMbps=65
        model.updateGameVideo(video);model.disconnect()
        let renamed=MockHost(paired:true,singleAppID:99,singleAppUUID:uuid.lowercased(),singleAppName:"Renamed")
        let restarted=ConnectionModel(vault:MemoryVault(),rememberHost:false,profiles:profiles,makeHost:{ _,_,_,_ in renamed })
        restarted.address="pc.local";restarted.connect();try await settle(restarted)
        XCTAssertEqual(restarted.selectedAppID,99);XCTAssertEqual(restarted.effectiveVideoSettings,video)
        restarted.disconnect()
    }
    func testMissingHostAndAppUUIDsUseEndpointAndNumericAppFallbacks() async throws {
        let profiles=StreamProfilesStore(storage:nil)
        let mock=MockHost(paired:true,uniqueID:"",singleAppUUID:"")
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,profiles:profiles,makeHost:{ _,_,_,_ in mock })
        model.address="pc.local";model.connect();try await settle(model)
        XCTAssertEqual(model.hostProfileKey,"endpoint:pc.local:47989")
        XCTAssertEqual(model.gameProfileKey,"app-id:1")
        model.gameVideoSource = .custom
        var video=model.effectiveVideoSettings;video.fps=120
        model.updateGameVideo(video);model.disconnect()
        model.address="other.local";model.connect();try await settle(model)
        XCTAssertEqual(model.effectiveVideoSettings.fps,60,"Missing host ID must not share settings across endpoints")
        model.disconnect()
    }
    func testHostAndGameProfilesFollowSelectionAndSurviveAddressChanges() async throws {
        let storage=MemorySettingsPreferences(),profiles=StreamProfilesStore(storage:storage)
        let settings=AppSettings(storage:nil),mock=MockHost(paired:true,multipleApps:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,settings:settings,profiles:profiles,makeHost:{ _,_,_,_ in mock })
        model.address="127.0.0.1";model.connect();try await settle(model)
        let host=try XCTUnwrap(model.hostProfileKey)
        var hostVideo=StreamVideoSettings();hostVideo.resolution="3840x2160";hostVideo.fps=120;hostVideo.bitrateMbps=70
        model.updateHostVideo(hostVideo,hostKey:host)
        XCTAssertEqual(model.effectiveVideoSettings,hostVideo)
        XCTAssertEqual(settings.value.resolution,"1920x1080")
        model.selectedAppID=1;model.gameVideoSource = .custom
        var gameVideo=model.effectiveVideoSettings;gameVideo.resolution="2560x1440";gameVideo.framePacing = .balanced
        model.updateGameVideo(gameVideo)
        model.selectedAppID=2
        XCTAssertEqual(model.effectiveVideoSettings,hostVideo)
        model.gameVideoSource = .global
        settings.update { $0.bitrateMbps=35 }
        XCTAssertEqual(model.effectiveVideoSettings,settings.value.videoSettings)
        model.selectedAppID=1;XCTAssertEqual(model.effectiveVideoSettings,gameVideo)
        model.updateHostVideo(nil,hostKey:"another-host")
        XCTAssertNotNil(profiles.value.hostVideo(for:host),"A stale host editor cannot change the current host")
        model.disconnect()
        let restarted=ConnectionModel(vault:MemoryVault(),rememberHost:false,settings:settings,profiles:StreamProfilesStore(storage:storage),makeHost:{ _,_,_,_ in mock })
        restarted.address="pc.local";restarted.connect();try await settle(restarted)
        XCTAssertEqual(restarted.hostProfileKey,host,"Stable host ID survives an address change")
        restarted.selectedAppID=1;XCTAssertEqual(restarted.effectiveVideoSettings,gameVideo)
        restarted.gameVideoSource = .host
        XCTAssertEqual(restarted.effectiveVideoSettings,hostVideo)
        restarted.updateHostVideo(nil,hostKey:host)
        XCTAssertEqual(restarted.effectiveVideoSettings,settings.value.videoSettings)
        restarted.disconnect()
    }
    func testHostProfilesDoNotLeakToDifferentHostsWithTheSameAppIDs() async throws {
        let profiles=StreamProfilesStore(storage:nil)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,profiles:profiles,makeHost:{ address,_,_,_ in
            MockHost(paired:true,uniqueID:address)
        })
        model.address="first.local";model.connect();try await settle(model)
        model.gameVideoSource = .custom
        var video=model.effectiveVideoSettings;video.fps=120
        model.updateGameVideo(video)
        model.disconnect()
        model.address="second.local";model.connect();try await settle(model)
        XCTAssertEqual(model.gameVideoSource,.host)
        XCTAssertEqual(model.effectiveVideoSettings.fps,60)
        model.disconnect()
    }
    func testSelectedGameProfileReachesLaunchAndStillChecksHostHDRSupport() async throws {
        let mock=MockHost(paired:true,multipleApps:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        await model.prepare()
        guard (model.capabilities?.supportedFormats ?? 0) & 1 != 0 else { throw XCTSkip("No H.264 hardware") }
        model.address="127.0.0.1";model.connect();try await settle(model)
        model.gameVideoSource = .custom
        var video=model.effectiveVideoSettings
        video.resolution="2560x1440";video.fps=120;video.codec="h264"
        model.updateGameVideo(video)
        model.play();try await settle(model)
        let options=try XCTUnwrap(mock.launchedOptions)
        XCTAssertEqual(options.width,2560);XCTAssertEqual(options.height,1440);XCTAssertEqual(options.fps,120)
        XCTAssertEqual(model.settings.value.resolution,"1920x1080")
        guard (model.capabilities?.supportedFormats ?? 0) & 0x200 != 0 else { model.disconnect();return }
        video.hdr=true;video.codec="hevc";model.updateGameVideo(video)
        model.play();try await settle(model)
        XCTAssertEqual(model.errorMessage,"This app does not advertise HDR support.")
        model.disconnect()
    }
    func testPairedHostLoadsApplications() async throws {
        let mock = MockHost(paired: true)
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false, makeHost: { _, _, _, _ in mock })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect()
        try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.host?.name, "Test Host")
        XCTAssertEqual(model.apps.first?.name, "Desktop")
        model.disconnect()
        XCTAssertEqual(model.phase, .idle)
    }
    func testPairingPersistsPinAndLoadsApps() async throws {
        let mock = MockHost(paired: false), vault = MemoryVault()
        let model = ConnectionModel(vault: vault, rememberHost: false, makeHost: { _, _, _, _ in mock })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        XCTAssertEqual(model.host?.paired, false)
        model.pair()
        XCTAssertEqual(model.pairingPIN?.count, 4)
        try await settle(model)
        XCTAssertEqual(model.host?.paired, true)
        XCTAssertEqual(try vault.certificate(for: "127.0.0.1:47989"), "pinned certificate")
        XCTAssertEqual(model.apps.count, 1)
        XCTAssertNil(model.pairingPIN)
    }
    func testLaunchFailureKeepsLibraryAvailableForRetry() async throws {
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false, makeHost: { _, _, _, _ in MockHost(paired: true) })
        await model.prepare()
        guard model.capabilities?.supportedFormats ?? 0 != 0 else { throw XCTSkip("No hardware decoder available") }
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        model.play(); try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.errorMessage, "not used")
        XCTAssertTrue(model.canPlay)
        XCTAssertEqual(model.apps.count, 1)
    }
    func testDisconnectIgnoresLateResponse() async throws {
        let mock = MockHost(paired: true, delay: true)
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false, makeHost: { _, _, _, _ in mock })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect()
        try await Task.sleep(for: .milliseconds(30))
        model.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.host); XCTAssertTrue(model.apps.isEmpty)
    }
    func testCredentialFailureIsVisible() async throws {
        let model = ConnectionModel(vault: MemoryVault(failSave: true), rememberHost: false, makeHost: { _, _, _, _ in MockHost(paired: false) })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        model.pair(); try await settle(model)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.errorMessage?.contains("Keychain") == true)
        XCTAssertTrue(model.apps.isEmpty)
    }
    func testInvalidAddressAndPort() {
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false)
        model.address = "https://host"; model.connect()
        XCTAssertEqual(model.phase, .failed)
        model.address = "host"; model.port = "65536"; model.connect()
        XCTAssertEqual(model.phase, .failed)
    }
    func testSuccessfulConnectionSavesNameAndReusesExactEndpointPin() async throws {
        let preferences=MemoryHostPreferences(),vault=MemoryVault()
        let endpoint=try XCTUnwrap(HostEndpoint(address:"PC.LOCAL",port:48000))
        try vault.saveCertificate("existing pin",for:endpoint.id)
        let mock=MockHost(paired:true)
        let calls=HostFactoryCalls()
        let model=ConnectionModel(vault:vault,preferences:preferences,makeHost: { address,port,_,certificate in
            calls.record(address:address,port:port,certificate:certificate);return mock
        })
        model.connect(to:endpoint);try await settle(model)
        XCTAssertEqual(calls.certificate,"existing pin")
        XCTAssertEqual(calls.address,"pc.local");XCTAssertEqual(calls.port,48000)
        XCTAssertEqual(model.savedHosts.hosts.first?.name,"Test Host")
        XCTAssertEqual(model.savedHosts.hosts.first?.endpoint,endpoint)
        model.disconnect()
        XCTAssertEqual(SavedHosts(storage:preferences).hosts.first?.uniqueID,"host1")
        // Removing an entry is not an unpair operation.
        model.savedHosts.remove(endpoint)
        XCTAssertEqual(try vault.certificate(for:endpoint.id),"existing pin")
    }
    func testLibrarySearchSortFilterAndSelection() async throws {
        let settings=AppSettings(storage:nil),mock=MockHost(paired:true,multipleApps:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,settings:settings,makeHost:{ _,_,_,_ in mock })
        model.address="127.0.0.1";model.port="47989";model.connect();try await settle(model)
        XCTAssertEqual(model.filteredApps.map(\.name),["Alpha","Desktop","Zulu"])
        XCTAssertEqual(model.selectedAppID,2)
        settings.update { $0.librarySort="host" }
        XCTAssertEqual(model.filteredApps.map(\.id),[1,2,3])
        model.libraryQuery="ZULU";XCTAssertEqual(model.selectedAppID,3)
        model.libraryHDROnly=true;XCTAssertEqual(model.filteredApps.count,1)
        model.libraryQuery="Alpha";XCTAssertTrue(model.filteredApps.isEmpty);XCTAssertNil(model.selectedAppID)
        XCTAssertFalse(model.canPlay)
        model.disconnect()
    }
    func testSavedStreamDefaultsReachHostLaunch() async throws {
        let storage=MemorySettingsPreferences(),settings=AppSettings(storage:storage)
        settings.update { $0.resolution="3024x1890";$0.fps=120;$0.audioLayout="5.1";$0.codec="h264" }
        let restarted=AppSettings(storage:storage),mock=MockHost(paired:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,settings:restarted,makeHost:{ _,_,_,_ in mock })
        await model.prepare()
        guard (model.capabilities?.supportedFormats ?? 0) & 1 != 0 else { throw XCTSkip("No H.264 hardware available") }
        model.address="127.0.0.1";model.port="47989";model.connect();try await settle(model)
        model.play();try await settle(model)
        let launch=try XCTUnwrap(mock.launchedOptions)
        XCTAssertEqual(launch.width,3024);XCTAssertEqual(launch.height,1890);XCTAssertEqual(launch.fps,120)
        XCTAssertEqual(launch.channelCount,6);XCTAssertEqual(launch.channelMask,0x3F)
        model.disconnect()
    }
    func testMicrophonePermissionDenialPreventsHostLaunch() async throws {
        let settings=AppSettings(storage:nil),mock=MockHost(paired:true)
        settings.update { $0.microphoneEnabled=true }
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,microphonePermission:{ false },settings:settings,makeHost:{ _,_,_,_ in mock })
        await model.prepare()
        guard model.capabilities?.supportedFormats ?? 0 != 0 else { throw XCTSkip("No hardware decoder") }
        model.address="127.0.0.1";model.port="47989";model.connect();try await settle(model)
        model.play();try await settle(model)
        XCTAssertNil(mock.launchedOptions)
        XCTAssertTrue(model.errorMessage?.contains("Microphone") == true)
        model.disconnect()
    }
    private func settle(_ model: ConnectionModel) async throws {
        for _ in 0..<200 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Host operation did not finish")
    }
}

private final class MockHost: HostService, @unchecked Sendable {
    let lock = NSLock()
    private var paired: Bool
    let delay: Bool
    let multipleApps: Bool
    let uniqueID: String
    let singleAppID: Int32
    let singleAppUUID: String
    let singleAppName: String
    private var launchOptions: LaunchOptions?
    var launchedOptions: LaunchOptions? { lock.withLock { launchOptions } }
    init(paired: Bool, delay: Bool = false,multipleApps: Bool = false,uniqueID: String = "host1",
         singleAppID: Int32 = 1,singleAppUUID: String = "app1",singleAppName: String = "Desktop") {
        self.paired=paired;self.delay=delay;self.multipleApps=multipleApps;self.uniqueID=uniqueID
        self.singleAppID=singleAppID;self.singleAppUUID=singleAppUUID;self.singleAppName=singleAppName
    }
    func serverInfo() async throws -> HostInfo {
        if delay { try await Task.sleep(for: .milliseconds(120)) }
        let isPaired = lock.withLock { paired }
        return try decode("{\"name\":\"Test Host\",\"uniqueID\":\"\(uniqueID)\",\"paired\":\(isPaired),\"appVersion\":\"7.1.431.-1\",\"codecSupport\":1,\"currentGame\":0}")
    }
    func pair(pin: String) async throws -> PairedHost {
        lock.withLock { paired = true }
        return try decode("{\"certificate\":\"pinned certificate\",\"uniqueID\":\"host1\"}")
    }
    func apps() async throws -> [HostApp] {
        if multipleApps { return try decode("[{\"id\":1,\"name\":\"Desktop\",\"uuid\":\"app1\",\"hdrSupported\":true},{\"id\":2,\"name\":\"Alpha\",\"uuid\":\"app2\",\"hdrSupported\":false},{\"id\":3,\"name\":\"Zulu\",\"uuid\":\"app3\",\"hdrSupported\":true}]") }
        return try JSONDecoder().decode([HostApp].self,from:JSONSerialization.data(withJSONObject:
            [["id":singleAppID,"name":singleAppName,"uuid":singleAppUUID,"hdrSupported":true]]))
    }
    func launch(_ options: LaunchOptions) async throws -> LaunchedStream { lock.withLock { launchOptions=options };throw HostConnectionError("not used") }
    func cancel() {}
}
private final class MemoryVault: CredentialsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var certificates: [String:String] = [:]
    let failSave: Bool
    init(failSave: Bool = false) { self.failSave = failSave }
    func identity() throws -> ClientIdentity { try decode("{\"uniqueID\":\"test\",\"certificate\":\"test\",\"privateKey\":\"test\"}") }
    func certificate(for endpoint: String) throws -> String? { lock.withLock { certificates[endpoint] } }
    func saveCertificate(_ certificate: String, for endpoint: String) throws {
        if failSave { throw HostConnectionError("Keychain test failure") }
        lock.withLock { certificates[endpoint] = certificate }
    }
}
private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }

private final class HostFactoryCalls: @unchecked Sendable {
    private let lock=NSLock()
    private var values: (String,UInt16,String?) = ("",0,nil)
    func record(address: String,port: UInt16,certificate: String?) { lock.withLock { values=(address,port,certificate) } }
    var address: String { lock.withLock { values.0 } }
    var port: UInt16 { lock.withLock { values.1 } }
    var certificate: String? { lock.withLock { values.2 } }
}
