import XCTest
import Foundation
import MysticKit
import MysticCore
@testable import MysticDesktop

@MainActor
final class ConnectionModelTests: XCTestCase {
    func testHomeRefreshKeepsOfflineGamesAndDoesNotUseUnpinnedHosts() async throws {
        let vault=MemoryVault(),home=HomeLibrary()
        let model=ConnectionModel(vault:vault,rememberHost:false,home:home,makeHost:{ address,_,_,pin in
            XCTAssertNotNil(pin)
            if address == "offline.local" { throw HostConnectionError("PC unreachable") }
            return MockHost(paired:true,uniqueID:address)
        })
        for address in ["online.local","offline.local","unpaired.local"] {
            let endpoint=HostEndpoint(address:address,port:47989)!
            model.savedHosts.remember(endpoint:endpoint,name:address,uniqueID:address)
            if address != "unpaired.local" { try vault.saveCertificate("pinned",for:endpoint.id) }
        }
        let info: HostInfo=try decode(#"{"name":"Offline","uniqueID":"offline.local","paired":true,"codecSupport":1,"currentGame":0}"#)
        let apps=try await MockHost(paired:true).apps()
        home.record(host:info,endpoint:HostEndpoint(address:"offline.local",port:47989)!,apps:apps,library:nil)
        await model.homeSync.refresh()
        XCTAssertEqual(home.pcs.count,2)
        XCTAssertEqual(home.reach["host:online.local"],.online)
        XCTAssertEqual(home.reach["host:offline.local"],.offline)
        XCTAssertEqual(home.reach["host:unpaired.local"],.pairing)
        XCTAssertNotNil(home.pc("host:offline.local"))
        model.removeSavedHost(HostEndpoint(address:"offline.local",port:47989)!)
        XCTAssertNil(home.pc("host:offline.local"))
        model.disconnect()
    }
    func testHomeLaunchUsesChosenHostAndItsGameProfile() async throws {
        let vault=MemoryVault(),home=HomeLibrary(),mock=MockHost(paired:true,uniqueID:"second")
        let endpoint=HostEndpoint(address:"second.local",port:47989)!
        try vault.saveCertificate("pin",for:endpoint.id)
        let info: HostInfo=try decode(#"{"name":"Second","uniqueID":"second","paired":true,"codecSupport":1,"currentGame":0}"#)
        home.record(host:info,endpoint:endpoint,apps:try await mock.apps(),library:nil)
        let model=ConnectionModel(vault:vault,rememberHost:false,home:home,makeHost:{ address,_,_,_ in XCTAssertEqual(address,"second.local");return mock })
        await model.prepare()
        guard (model.capabilities?.supportedFormats ?? 0) & 1 != 0 else { throw XCTSkip("No H.264 hardware") }
        var video=StreamVideoSettings();video.resolution="1280x720";video.codec="h264"
        model.profiles.update { try $0.setGame(source:.custom,video:video,host:"id:second",game:"uuid:app1") }
        await model.openHomeGame(try XCTUnwrap(home.games.first?.copies.first));try await settle(model)
        XCTAssertEqual(mock.launchedOptions?.width,1280)
        XCTAssertEqual(mock.launchedOptions?.appUUID,"app1")
        XCTAssertFalse(model.showingHome)
        XCTAssertNil(home.games.first?.lastPlayed,"An attempted launch is not recent play until connected")
        model.disconnect()
    }
    func testQuitNeedsConfirmationAndRejectsChangedGamesAndOldConnections() async throws {
        let mock=MockHost(paired:true,multipleApps:true)
        mock.lock.withLock { mock.runningGame=1 }
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="pc.local";model.connect();try await settle(model)
        await model.requestGameAction(startSelected:false)
        XCTAssertNotNil(model.pendingGameAction)
        XCTAssertEqual(mock.lock.withLock { mock.quitCalls },0)
        model.cancelGameAction()
        XCTAssertNil(model.pendingGameAction)
        await model.requestGameAction(startSelected:false)
        let old=try XCTUnwrap(model.pendingGameAction)
        model.disconnect();model.connect();try await settle(model)
        await model.confirmGameAction(old)
        XCTAssertEqual(mock.lock.withLock { mock.quitCalls },0)
        await model.requestGameAction(startSelected:false)
        let changed=try XCTUnwrap(model.pendingGameAction)
        mock.lock.withLock { mock.runningGame=2 }
        await model.confirmGameAction(changed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(mock.lock.withLock { mock.runningGame },2)
        await model.requestGameAction(startSelected:false)
        await model.confirmGameAction(try XCTUnwrap(model.pendingGameAction))
        XCTAssertEqual(model.host?.currentGame,0)
        XCTAssertEqual(model.phase,.ready)
        XCTAssertEqual(mock.lock.withLock { mock.launchCalls },0)
        model.disconnect()
    }
    func testSwitchCapturesTargetProfileAndNeverLaunchesAfterRefusedQuit() async throws {
        let mock=MockHost(paired:true,multipleApps:true)
        mock.lock.withLock { mock.runningGame=1 }
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        await model.prepare()
        guard (model.capabilities?.supportedFormats ?? 0) & 1 != 0 else { throw XCTSkip("No H.264 hardware") }
        model.address="pc.local";model.connect();try await settle(model)
        model.library.selectedID=2;model.gameVideoSource = .custom
        var video=model.effectiveVideoSettings;video.codec="h264";video.hdr=false;video.resolution="1280x720"
        model.updateGameVideo(video)
        await model.requestGameAction(startSelected:true)
        let action=try XCTUnwrap(model.pendingGameAction)
        XCTAssertEqual(action.target?.id,2)
        model.library.selectedID=3
        await model.confirmGameAction(action);try await settle(model)
        XCTAssertEqual(mock.launchedOptions?.appID,2)
        XCTAssertEqual(mock.launchedOptions?.width,1280)
        mock.lock.withLock { mock.runningGame=1;mock.quitRefused=true }
        model.library.selectedID=2
        await model.requestGameAction(startSelected:true)
        await model.confirmGameAction(try XCTUnwrap(model.pendingGameAction));try await settle(model)
        XCTAssertEqual(mock.lock.withLock { mock.launchCalls },1)
        XCTAssertNotNil(model.errorMessage)
        let quits=mock.lock.withLock { mock.quitCalls }
        model.library.selectedID=2;video.hdr=true;model.updateGameVideo(video)
        await model.requestGameAction(startSelected:true)
        XCTAssertNil(model.pendingGameAction,"Invalid target settings must fail before a quit confirmation")
        XCTAssertEqual(mock.lock.withLock { mock.quitCalls },quits)
        model.disconnect()
    }
    func testGraphicsReadbackFailureRecoveryAndConnectionIsolation() async throws {
        let mock=MockHost(paired:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="pc.local";model.connect();try await settle(model)
        await model.graphics.refresh()
        XCTAssertTrue(model.graphics.canWrite)
        let context=model.contextID
        mock.lock.withLock { mock.graphicsFails=true }
        await model.graphics.write(gpu:1,setting:"anti_lag.enabled",value:.toggle(true),context:context)
        XCTAssertNotNil(model.graphics.writeError)
        XCTAssertEqual(model.graphics.panel?.gpus.first?.settings.first?.value,.toggle(true),"Failed writes read back partially applied host state")
        XCTAssertFalse(model.graphics.writing)
        mock.lock.withLock { mock.graphicsFails=false }
        await model.graphics.write(gpu:1,setting:"anti_lag.enabled",value:.toggle(false),context:context)
        XCTAssertNil(model.graphics.writeError)
        XCTAssertEqual(model.graphics.panel?.gpus.first?.settings.first?.value,.toggle(false))
        let panel=try XCTUnwrap(model.graphics.panel),session=try XCTUnwrap(model.graphics.session)
        await model.graphics.restore(panel:panel,session:session,context:context)
        XCTAssertEqual(mock.lock.withLock { mock.graphicsRestores },1)
        XCTAssertEqual(model.graphics.panel?.gpus.first?.settings.first?.value,.toggle(false))
        model.disconnect();XCTAssertNil(model.graphics.panel)
        model.connect();try await settle(model);await model.graphics.refresh()
        await model.graphics.write(gpu:1,setting:"anti_lag.enabled",value:.toggle(true),context:context)
        XCTAssertEqual(mock.lock.withLock { mock.graphicsWrites },2,"An old window must not write to another connection")
        let reading=Task { await model.graphics.refresh() }
        try await Task.sleep(for:.milliseconds(5));model.disconnect();await reading.value
        XCTAssertNil(model.graphics.panel);XCTAssertFalse(model.graphics.reading)
    }
    func testIntentionalHostExitSuppressesRecoveryAndFailureAllowsRetry() async throws {
        let mock=MockHost(paired:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="pc.local";model.connect();try await settle(model)
        await model.sessionControls.refresh()
        XCTAssertTrue(model.sessionControls.snapshot?.allows(.end) == true)
        mock.lock.withLock { mock.sessionActionFails=true }
        await model.sessionControls.perform(.end)
        XCTAssertEqual(model.phase,.ready)
        XCTAssertNotNil(model.sessionControls.message)
        XCTAssertFalse(model.sessionControls.busy)
        mock.lock.withLock { mock.sessionActionFails=false }
        await model.sessionControls.refresh()
        let action=Task { await model.sessionControls.perform(.end) }
        for _ in 0..<100 {
            if model.sessionControls.busy { break }
            try await Task.sleep(for:.milliseconds(2))
        }
        XCTAssertTrue(model.sessionControls.busy)
        model.connectionEnded(code:-1,videoStarted:true)
        XCTAssertNotEqual(model.phase,.reconnecting)
        await action.value
        XCTAssertEqual(model.phase,.idle)
        XCTAssertFalse(model.sessionControls.busy)
        XCTAssertNil(model.sessionControls.snapshot)
    }
    func testLateSessionReadCannotPopulateAnotherHost() async throws {
        let mock=MockHost(paired:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="pc.local";model.connect();try await settle(model)
        let oldContext=model.contextID
        let read=Task { await model.sessionControls.refresh() }
        try await Task.sleep(for:.milliseconds(5))
        model.disconnect()
        await read.value
        XCTAssertNil(model.sessionControls.snapshot)
        XCTAssertEqual(model.phase,.idle)
        model.connect();try await settle(model);await model.sessionControls.refresh()
        await model.sessionControls.perform(.end,context:oldContext)
        XCTAssertEqual(model.phase,.ready,"A confirmation from a previous connection cannot target this host")
        model.disconnect()
    }
    func testNativeLibrarySearchRefreshProfilesAndFailureFallback() async throws {
        let mock=MockHost(paired:true,native:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="pc.local";model.connect();try await settle(model)
        XCTAssertEqual(model.library.selected?.name,"Native Game")
        XCTAssertTrue(model.library.selectedRunning)
        model.library.query="Steam";XCTAssertEqual(model.library.filtered.count,1)
        model.gameVideoSource = .custom
        var video=model.effectiveVideoSettings;video.fps=120
        model.updateGameVideo(video)
        model.refreshLibrary();try await settle(model)
        XCTAssertEqual(model.effectiveVideoSettings.fps,120)
        XCTAssertEqual(model.gameProfileKey,"uuid:app1")
        mock.lock.withLock { mock.libraryFails=true }
        model.library.query="";model.refreshLibrary();try await settle(model)
        XCTAssertEqual(model.library.apps.first?.name,"Desktop")
        XCTAssertNotNil(model.library.notice)
        XCTAssertEqual(model.phase,.ready)
        XCTAssertEqual(model.effectiveVideoSettings.fps,120)
        model.disconnect();XCTAssertNil(model.library.native)
        XCTAssertTrue(model.library.artwork.isEmpty)
    }
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
        XCTAssertEqual(restarted.library.selectedID,99);XCTAssertEqual(restarted.effectiveVideoSettings,video)
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
        XCTAssertEqual(model.effectiveVideoSettings.fps,StreamPreferences.displayFrameRate,"Missing host ID must not share settings across endpoints")
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
        XCTAssertEqual(settings.value.resolution,StreamPreferences.nativeResolution)
        model.library.selectedID=1;model.gameVideoSource = .custom
        var gameVideo=model.effectiveVideoSettings;gameVideo.resolution="2560x1440";gameVideo.framePacing = .balanced
        model.updateGameVideo(gameVideo)
        model.library.selectedID=2
        XCTAssertEqual(model.effectiveVideoSettings,hostVideo)
        model.gameVideoSource = .global
        settings.update { $0.bitrateMbps=35 }
        XCTAssertEqual(model.effectiveVideoSettings,settings.value.videoSettings)
        model.library.selectedID=1;XCTAssertEqual(model.effectiveVideoSettings,gameVideo)
        model.updateHostVideo(nil,hostKey:"another-host")
        XCTAssertNotNil(profiles.value.hostVideo(for:host),"A stale host editor cannot change the current host")
        model.disconnect()
        let restarted=ConnectionModel(vault:MemoryVault(),rememberHost:false,settings:settings,profiles:StreamProfilesStore(storage:storage),makeHost:{ _,_,_,_ in mock })
        restarted.address="pc.local";restarted.connect();try await settle(restarted)
        XCTAssertEqual(restarted.hostProfileKey,host,"Stable host ID survives an address change")
        restarted.library.selectedID=1;XCTAssertEqual(restarted.effectiveVideoSettings,gameVideo)
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
        XCTAssertEqual(model.effectiveVideoSettings.fps,StreamPreferences.displayFrameRate)
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
        XCTAssertEqual(model.settings.value.resolution,StreamPreferences.nativeResolution)
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
        XCTAssertEqual(model.library.apps.first?.name, "Desktop")
        model.disconnect()
        XCTAssertEqual(model.phase, .idle)
    }
    func testAPairingLinkConnectsUnpinnedAndPairsAtOnceWithoutKeepingItsSecret() async throws {
        let mock=MockHost(paired:false),vault=MemoryVault()
        try vault.saveCertificate("old certificate",for:"192.168.4.2:48123")
        nonisolated(unsafe) var pins:[String?]=[],places:[String]=[]
        let model=ConnectionModel(vault:vault,rememberHost:false,makeHost:{ address,port,_,pin in pins.append(pin);places.append("\(address):\(port)");return mock })
        model.parseLink={ XCTAssertEqual($0,"rubylight://pair?secret");return PairingLinkTarget(host:"192.168.4.2",port:48123,name:"Den",uniqueID:"host1") }
        model.connect(pairingLink:"rubylight://pair?secret")
        try await settle(model)
        XCTAssertEqual(places,["192.168.4.2:48123"]);XCTAssertEqual(pins,[nil],"the link names the certificate; the old pin is not used")
        XCTAssertEqual(mock.pairedLinks,["rubylight://pair?secret"])
        XCTAssertEqual(model.address,"192.168.4.2");XCTAssertEqual(model.port,"48123")
        XCTAssertEqual(try vault.certificate(for:"192.168.4.2:48123"),"pinned certificate")
        XCTAssertEqual(model.phase,.ready);XCTAssertEqual(model.host?.paired,true);XCTAssertFalse(model.library.apps.isEmpty)
        XCTAssertNil(model.pairingError)
    }
    func testABadLinkIsRefusedAsALinkAndNeverConnects() {
        nonisolated(unsafe) var made=0
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in made+=1;return MockHost(paired:false) })
        model.connect(pairingLink:"rubylight://pair?v=2")
        XCTAssertEqual(made,0);XCTAssertEqual(model.phase,.failed);XCTAssertFalse(model.showingHome,"Home shows no connection errors")
        XCTAssertTrue(model.errorMessage?.contains("not valid") == true)
        XCTAssertFalse(model.address.contains("rubylight"))
        XCTAssertTrue(ConnectionModel.isPairingLink("  rubylight://pair?v=1\n"));XCTAssertFalse(ConnectionModel.isPairingLink("192.168.1.2"))
    }
    func testASpentLinkKeepsThePairingViewAndSaysWhy() async throws {
        let mock=MockHost(paired:false);mock.oneTimeFailure="PIN rejected. Generate a new one-time PIN."
        let vault=MemoryVault()
        let model=ConnectionModel(vault:vault,rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.parseLink={ _ in PairingLinkTarget(host:"den.local",port:47989,name:"",uniqueID:"") }
        model.connect(pairingLink:"rubylight://pair?secret");try await settle(model)
        XCTAssertEqual(model.phase,.ready);XCTAssertEqual(model.host?.paired,false)
        XCTAssertEqual(model.pairingError,"PIN rejected. Generate a new one-time PIN.")
        XCTAssertNil(try vault.certificate(for:"den.local:47989"),"a failure pins nothing")
    }
    func testAFailedLinkLeavesASavedPairedHostAsItWas() async throws {
        let preferences=MemoryHostPreferences(),vault=MemoryVault(),endpoint=HostEndpoint(address:"pc.local",port:47989)!
        try vault.saveCertificate("existing pin",for:endpoint.id)
        let paired=MockHost(paired:true),unpinned=MockHost(paired:false);unpinned.oneTimeFailure="spent"
        nonisolated(unsafe) var pins:[String?]=[]
        let model=ConnectionModel(vault:vault,rememberHost:true,preferences:preferences,settings:AppSettings(storage:MemorySettingsPreferences()),home:HomeLibrary(),makeHost:{ _,_,_,pin in pins.append(pin);return pin == nil ? unpinned : paired })
        model.parseLink={ _ in PairingLinkTarget(host:"pc.local",port:47989,name:"",uniqueID:"") }
        model.connect(to:endpoint);try await settle(model)
        XCTAssertEqual(model.savedHosts.hosts.first?.uniqueID,"host1")
        model.disconnect()
        model.connect(pairingLink:"rubylight://pair?secret");try await settle(model)
        XCTAssertEqual(model.pairingError,"spent")
        XCTAssertEqual(model.savedHosts.hosts.first?.uniqueID,"host1","the saved identity survives")
        XCTAssertEqual(try vault.certificate(for:endpoint.id),"existing pin")
        model.disconnect()
        model.connect(to:endpoint);try await settle(model)
        XCTAssertEqual(pins,["existing pin",nil,"existing pin"]);XCTAssertEqual(model.host?.paired,true)
    }
    func testAHostsWebUILinkIsOnlyEverAWebAddress() throws {
        XCTAssertEqual(HostWebUI(url:"https://100.66.0.33:47990").link?.absoluteString,"https://100.66.0.33:47990")
        XCTAssertEqual(HostWebUI(url:"https://[::1]:47990").link?.port,47990)
        for bad in ["file:///etc/passwd","javascript:alert(1)","mystic://stream","http://pc:47990","https://"] { XCTAssertNil(HostWebUI(url:bad).link,bad) }
        XCTAssertNil(HostWebUI(problem:"no link").link)
        let info:HostInfo=try decode("{\"name\":\"PC\",\"uniqueID\":\"a\",\"paired\":true,\"codecSupport\":0,\"currentGame\":0,\"software\":\"Rubylight 3.2.1\",\"permissions\":[\"View streams\"],\"webUI\":{\"url\":\"https://pc:47990\"}}")
        XCTAssertEqual(info.software,"Rubylight 3.2.1");XCTAssertEqual(info.permissions,["View streams"]);XCTAssertNotNil(info.webUI?.link)
        let old:HostInfo=try decode("{\"name\":\"PC\",\"uniqueID\":\"a\",\"paired\":true,\"codecSupport\":0,\"currentGame\":0}")
        XCTAssertNil(old.software);XCTAssertNil(old.permissions);XCTAssertNil(old.webUI)
    }
    func testOneTimePINPairsOnlyWithAValidEntry() async throws {
        let mock=MockHost(paired:false),vault=MemoryVault()
        let model=ConnectionModel(vault:vault,rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="den.local";model.connect();try await settle(model)
        for (pin,passphrase) in [("123","secret"),("12a4","secret"),("1234","abc")] {
            model.pair(oneTimePIN:pin,passphrase:passphrase)
            XCTAssertEqual(model.phase,.ready);XCTAssertNotNil(model.pairingError)
        }
        XCTAssertTrue(mock.pairedOneTime.isEmpty)
        model.pair(oneTimePIN:"1234",passphrase:"secret");try await settle(model)
        XCTAssertEqual(mock.pairedOneTime.map(\.0),["1234"]);XCTAssertEqual(mock.pairedOneTime.map(\.1),["secret"])
        XCTAssertEqual(model.host?.paired,true);XCTAssertNil(model.pairingError)
    }
    func testABusyHostKeepsTheOneTimePINUnspent() async throws {
        let mock=MockHost(paired:false);mock.runningGame=7
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,makeHost:{ _,_,_,_ in mock })
        model.address="den.local";model.connect();try await settle(model)
        model.pair(oneTimePIN:"1234",passphrase:"secret")
        XCTAssertTrue(mock.pairedOneTime.isEmpty);XCTAssertEqual(model.pairingError,"Stop the host's stream, then pair again.")
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
        XCTAssertEqual(model.library.apps.count, 1)
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
        XCTAssertEqual(model.library.apps.count, 1)
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
        XCTAssertNil(model.host); XCTAssertTrue(model.library.apps.isEmpty)
    }
    func testCredentialFailureIsVisible() async throws {
        let model = ConnectionModel(vault: MemoryVault(failSave: true), rememberHost: false, makeHost: { _, _, _, _ in MockHost(paired: false) })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        model.pair(); try await settle(model)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.errorMessage?.contains("Keychain") == true)
        XCTAssertTrue(model.library.apps.isEmpty)
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
        let model=ConnectionModel(vault:vault,preferences:preferences,writesLog:false,makeHost: { address,port,_,certificate in
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
        XCTAssertEqual(model.library.filtered.map(\.name),["Alpha","Desktop","Zulu"])
        XCTAssertEqual(model.library.selectedID,2)
        settings.update { $0.librarySort="host" }
        XCTAssertEqual(model.library.filtered.map(\.id),[1,2,3])
        model.library.query="ZULU";XCTAssertEqual(model.library.selectedID,3)
        model.library.hdrOnly=true;XCTAssertEqual(model.library.filtered.count,1)
        model.library.query="Alpha";XCTAssertTrue(model.library.filtered.isEmpty);XCTAssertNil(model.library.selectedID)
        XCTAssertFalse(model.canPlay)
        model.disconnect()
    }
    func testSavedStreamDefaultsReachHostLaunch() async throws {
        let storage=MemorySettingsPreferences(),settings=AppSettings(storage:storage)
        settings.update { $0.resolution="3024x1890";$0.fps=120;$0.audioLayout="5.1";$0.codec="h264";$0.errorCorrection="30";$0.networkGraceSeconds=20 }
        let restarted=AppSettings(storage:storage),mock=MockHost(paired:true)
        let model=ConnectionModel(vault:MemoryVault(),rememberHost:false,settings:restarted,makeHost:{ _,_,_,_ in mock })
        await model.prepare()
        guard (model.capabilities?.supportedFormats ?? 0) & 1 != 0 else { throw XCTSkip("No H.264 hardware available") }
        model.address="127.0.0.1";model.port="47989";model.connect();try await settle(model)
        model.play();try await settle(model)
        let launch=try XCTUnwrap(mock.launchedOptions)
        XCTAssertEqual(launch.width,3024);XCTAssertEqual(launch.height,1890);XCTAssertEqual(launch.fps,120)
        XCTAssertEqual(launch.channelCount,6);XCTAssertEqual(launch.channelMask,0x3F)
        XCTAssertEqual(launch.fec,30,"The saved error correction reaches the launch request")
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
    let native: Bool
    var libraryFails=false
    var sessionActionFails=false
    var graphicsFails=false
    var graphicsValue=false
    var graphicsWrites=0
    var graphicsRestores=0
    var runningGame: Int32=0
    var pairedLinks:[String]=[]
    var pairedOneTime:[(String,String)]=[]
    var oneTimeFailure:String?
    var quitCalls=0
    var quitRefused=false
    var launchCalls=0
    let delay: Bool
    let multipleApps: Bool
    let uniqueID: String
    let singleAppID: Int32
    let singleAppUUID: String
    let singleAppName: String
    private var launchOptions: LaunchOptions?
    var launchedOptions: LaunchOptions? { lock.withLock { launchOptions } }
    init(paired: Bool, native: Bool = false, delay: Bool = false,multipleApps: Bool = false,uniqueID: String = "host1",
         singleAppID: Int32 = 1,singleAppUUID: String = "app1",singleAppName: String = "Desktop") {
        self.native=native;self.paired=paired;self.delay=delay;self.multipleApps=multipleApps;self.uniqueID=uniqueID
        self.singleAppID=singleAppID;self.singleAppUUID=singleAppUUID;self.singleAppName=singleAppName
    }
    func serverInfo() async throws -> HostInfo {
        if delay { try await Task.sleep(for: .milliseconds(120)) }
        let isPaired = lock.withLock { paired }
        let running=lock.withLock { runningGame }
        return try decode("{\"name\":\"Test Host\",\"uniqueID\":\"\(uniqueID)\",\"paired\":\(isPaired),\"appVersion\":\"7.1.431.-1\",\"codecSupport\":1,\"currentGame\":\(running)}")
    }
    func pair(pin: String,passphrase: String) async throws -> PairedHost {
        lock.withLock { pairedOneTime.append((pin,passphrase));paired = oneTimeFailure == nil }
        if let oneTimeFailure { throw HostConnectionError(oneTimeFailure) }
        return try decode("{\"certificate\":\"pinned certificate\",\"uniqueID\":\"host1\"}")
    }
    func pair(link: String) async throws -> PairedHost {
        lock.withLock { pairedLinks.append(link);paired = oneTimeFailure == nil }
        if let oneTimeFailure { throw HostConnectionError(oneTimeFailure) }
        return try decode("{\"certificate\":\"pinned certificate\",\"uniqueID\":\"host1\"}")
    }
    func pair(pin: String) async throws -> PairedHost {
        lock.withLock { paired = true }
        return try decode("{\"certificate\":\"pinned certificate\",\"uniqueID\":\"host1\"}")
    }
    func quitApp(expected: HostInfo) async throws {
        try lock.withLock {
            quitCalls += 1
            guard !quitRefused,expected.currentGame == runningGame else { throw HostConnectionError("The running game changed or quit was refused") }
            runningGame=0
        }
    }
    func apps() async throws -> [HostApp] {
        if multipleApps { return try decode("[{\"id\":1,\"name\":\"Desktop\",\"uuid\":\"app1\",\"hdrSupported\":true},{\"id\":2,\"name\":\"Alpha\",\"uuid\":\"app2\",\"hdrSupported\":false},{\"id\":3,\"name\":\"Zulu\",\"uuid\":\"app3\",\"hdrSupported\":true}]") }
        return try JSONDecoder().decode([HostApp].self,from:JSONSerialization.data(withJSONObject:
            [["id":singleAppID,"name":singleAppName,"uuid":singleAppUUID,"hdrSupported":true]]))
    }
    func graphics() async throws -> HostGraphics? {
        try await Task.sleep(for:.milliseconds(20))
        let value=lock.withLock { graphicsValue }
        return try decode("{\"revision\":1,\"state\":\"configurable\",\"host_control\":true,\"writable_now\":true,\"gpus\":[{\"id\":1,\"name\":\"Radeon\",\"driver\":\"test\",\"settings\":[{\"id\":\"anti_lag.enabled\",\"group\":\"anti_lag\",\"kind\":\"toggle\",\"state\":\"configurable\",\"value\":\(value)}]}]}")
    }
    func writeGraphics(gpu: Int32,setting: String,value: GraphicsValue,expected: HostGraphics,session: HostSession) async throws -> HostGraphics {
        let fail=lock.withLock {
            graphicsWrites += 1
            if case .toggle(let enabled)=value { graphicsValue=enabled }
            return graphicsFails
        }
        if fail { throw HostConnectionError("Driver rejected part of the change") }
        return try await graphics()!
    }
    func restoreGraphics(expected: HostGraphics,session: HostSession) async throws -> HostGraphics {
        lock.withLock { graphicsValue=false;graphicsRestores += 1 }
        return try await graphics()!
    }
    func hostSession() async throws -> HostSession? {
        try await Task.sleep(for:.milliseconds(20))
        return try decode(#"{"state":"streaming","owner":"you","app":{"app_id":1,"title":"Desktop"},"game_running":true,"actions":[{"id":"end","allowed":true}]}"#)
    }
    func performSessionAction(_ action: HostSessionAction,expected: HostSession) async throws -> HostSession {
        try await Task.sleep(for:.milliseconds(40))
        if lock.withLock({sessionActionFails}) { throw HostConnectionError("Host busy") }
        return try await hostSession()!
    }
    func library() async throws -> HostLibrary? {
        if lock.withLock({ libraryFails }) { throw HostConnectionError("Library unavailable") }
        guard native else { return nil }
        return try decode(#"{"revision":"1","games":[{"install_id":"install1","app_id":1,"title":"Native Game","store":{"source":"steam","name":"Steam"},"installed":true,"running":true,"artwork":{"cover":null,"version":"1"}}]}"#)
    }
    func launch(_ options: LaunchOptions) async throws -> LaunchedStream { lock.withLock { launchOptions=options;launchCalls += 1 };throw HostConnectionError("not used") }
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
