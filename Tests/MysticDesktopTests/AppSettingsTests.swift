import XCTest
import Foundation
import MysticCore
@testable import MysticDesktop

@MainActor
final class AppSettingsTests: XCTestCase {
    func testEditsPersistAcrossRestartAndRestoreDefaultsKeepsPane() {
        let storage=MemorySettingsPreferences()
        let settings=AppSettings(storage:storage)
        settings.update {
            $0.resolution="1280x720";$0.fps=120;$0.bitrateMbps=35;$0.codec="hevc"
            $0.audioLayout="5.1";$0.volume=0.4;$0.muted=true;$0.showLatencyHUD=true
            $0.libraryLayout="list";$0.discoveryEnabled=false;$0.settingsPane="audio"
        }
        let restarted=AppSettings(storage:storage)
        XCTAssertEqual(restarted.value,settings.value)
        restarted.restoreDefaults()
        var defaults=StreamPreferences();defaults.settingsPane="audio"
        XCTAssertEqual(restarted.value,defaults)
        XCTAssertEqual(AppSettings(storage:storage).value,defaults)
    }
    func testCorruptAndFutureSettingsFallBackAndRecover() {
        let storage=MemorySettingsPreferences()
        for data in [Data("not JSON".utf8),Data(repeating:0,count:65_537),Data("{\"version\":99,\"preferences\":{}}".utf8)] {
            storage.data=data
            let settings=AppSettings(storage:storage)
            XCTAssertNotNil(settings.error);XCTAssertEqual(settings.value,StreamPreferences())
            settings.update { $0.volume=0.5 }
            XCTAssertNil(settings.error)
            XCTAssertEqual(AppSettings(storage:storage).value.volume,0.5)
        }
    }
    func testSharedModelBindingsAndDiscoveryLifecycle() {
        let storage=MemorySettingsPreferences(),settings=AppSettings(storage:storage),transport=CountingDiscovery()
        let model=ConnectionModel(rememberHost:false,settings:settings,discovery:HostDiscovery(transport:transport))
        model.resolution="2560x1440";model.fps=120;model.volume=3
        XCTAssertEqual(settings.value.resolution,"2560x1440")
        XCTAssertEqual(settings.value.fps,120);XCTAssertEqual(model.volume,1)
        model.libraryAppeared();XCTAssertEqual(transport.starts,1)
        settings.update { $0.discoveryEnabled=false };model.applyLiveSettings()
        XCTAssertFalse(model.discovery.isRunning)
        settings.update { $0.discoveryEnabled=true };model.applyLiveSettings()
        XCTAssertEqual(transport.starts,2)
        model.libraryDisappeared();model.applyLiveSettings()
        XCTAssertFalse(model.discovery.isRunning)
    }
}
@MainActor
final class MemorySettingsPreferences: AppSettingsStorage {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data=data }
}
@MainActor
private final class CountingDiscovery: HostDiscoveryTransport {
    var starts=0
    func start(update: @escaping @MainActor ([DiscoveredHost]) -> Void,status: @escaping @MainActor (String) -> Void) { starts+=1 }
    func stop() {}
}
