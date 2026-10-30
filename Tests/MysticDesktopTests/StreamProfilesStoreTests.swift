import XCTest
import Foundation
import MysticCore
@testable import MysticDesktop

@MainActor
final class StreamProfilesStoreTests: XCTestCase {
    func testProfilesPersistSeparatelyFromGlobalSettingsAndSurviveGlobalReset() throws {
        let storage=MemorySettingsPreferences(),globalStorage=MemorySettingsPreferences()
        let store=StreamProfilesStore(storage:storage),globals=AppSettings(storage:globalStorage)
        globals.update { $0.fps=120;$0.volume=0.4 }
        var video=StreamVideoSettings();video.resolution="3840x2160";video.hdr=true
        store.update { try $0.setHost(video,host:"PC");try $0.setGame(source:.global,video:nil,host:"PC",game:"A") }
        let restarted=StreamProfilesStore(storage:storage)
        XCTAssertEqual(restarted.value,store.value);XCTAssertNil(restarted.error)
        XCTAssertEqual(AppSettings(storage:globalStorage).value.fps,120)
        globals.restoreDefaults()
        XCTAssertEqual(StreamProfilesStore(storage:storage).value.hostVideo(for:"PC"),video)
        XCTAssertEqual(StreamProfilesStore(storage:storage).value.source(host:"PC",game:"A"),.global)
    }
    func testBadProfileDocumentDoesNotResetGlobalPreferencesAndCanBeReplaced() {
        let storage=MemorySettingsPreferences(),globals=AppSettings(storage:nil)
        globals.update { $0.bitrateMbps=55;$0.codec="hevc" }
        for data in [Data("broken".utf8),Data("{\"version\":99,\"hosts\":{},\"games\":{}}".utf8)] {
            storage.data=data
            let store=StreamProfilesStore(storage:storage)
            XCTAssertNotNil(store.error)
            XCTAssertEqual(store.value.video(defaults:globals.value.videoSettings,host:"PC",game:"A"),globals.value.videoSettings)
            store.update { try $0.setHost(globals.value.videoSettings,host:"PC") }
            XCTAssertNil(store.error);XCTAssertNil(StreamProfilesStore(storage:storage).error)
            XCTAssertEqual(globals.value.bitrateMbps,55)
        }
    }
    func testFailedMutationPreservesSavedCatalog() throws {
        let storage=MemorySettingsPreferences(),store=StreamProfilesStore(storage:storage)
        store.update { try $0.setHost(StreamVideoSettings(),host:"PC") }
        let before=storage.data
        store.update { try $0.setHost(StreamVideoSettings(),host:"") }
        XCTAssertNotNil(store.error);XCTAssertEqual(storage.data,before)
        XCTAssertNotNil(store.value.hostVideo(for:"PC"))
    }
}
