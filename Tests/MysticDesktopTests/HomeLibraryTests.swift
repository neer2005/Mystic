import XCTest
import Foundation
import MysticCore
import MysticKit
@testable import MysticDesktop

@MainActor
final class HomeLibraryTests: XCTestCase {
    private func endpoint(_ name: String) -> HostEndpoint { HostEndpoint(address:name,port:47989)! }
    private func info(_ id: String) throws -> HostInfo {
        try JSONDecoder().decode(HostInfo.self,from:Data("{\"name\":\"\(id)\",\"uniqueID\":\"\(id)\",\"paired\":true,\"codecSupport\":1,\"currentGame\":0}".utf8))
    }
    private func apps(_ title: String = "Game",id: Int32 = 1) throws -> [HostApp] {
        try JSONDecoder().decode([HostApp].self,from:Data("[{\"id\":\(id),\"name\":\"\(title)\",\"uuid\":\"stable-game\",\"hdrSupported\":true},{\"id\":2,\"name\":\"Desktop\",\"uuid\":\"desktop\",\"hdrSupported\":true}]".utf8))
    }
    private func library(_ version: String = "v1",id: Int32 = 1) throws -> HostLibrary {
        try JSONDecoder().decode(HostLibrary.self,from:Data("{\"revision\":\"\(version)\",\"games\":[{\"game_id\":\"steam:570\",\"install_id\":\"install\",\"app_id\":\(id),\"title\":\"Game\",\"store\":{\"name\":\"Steam\",\"source\":\"steam\"},\"installed\":true,\"running\":false,\"artwork\":{\"cover\":\"/appasset\",\"version\":\"\(version)\"}}]}".utf8))
    }
    func testMergeKeepsHostCopiesSeparateAndPrefersReachablePC() throws {
        let home=HomeLibrary()
        home.record(host:try info("one"),endpoint:endpoint("one.local"),apps:try apps(),library:try library())
        home.record(host:try info("two"),endpoint:endpoint("two.local"),apps:try apps(),library:try library())
        XCTAssertEqual(home.games.count,3,"Shared store game merges; host-specific Desktops do not")
        home.setReach("host:one",.offline)
        let game=try XCTUnwrap(home.games.first { $0.id == "game:steam:570" })
        XCTAssertEqual(game.copies.count,2)
        XCTAssertEqual(game.copies.first?.hostID,"host:two")
        XCTAssertEqual(Set(game.copies.map(\.id)).count,2)
        home.toggleFavourite(game.id)
        home.played(hostID:"host:one",app:game.copies.first { $0.hostID == "host:one" }!.app,at:Date(timeIntervalSince1970:1000))
        XCTAssertTrue(home.games.first { $0.id == game.id }!.favourite)
        XCTAssertEqual(home.games.first { $0.id == game.id }?.lastPlayed,Date(timeIntervalSince1970:1000))
        XCTAssertEqual(home.games.count,3,"Unreachable PCs keep their games")
    }
    func testMetadataAndVersionedArtSurviveRestartButOnlineStateDoesNot() throws {
        let name="Mystic.HomeTests.\(UUID())",defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:root) }
        let home=HomeLibrary(defaults:defaults,artRoot:root)
        home.record(host:try info("one"),endpoint:endpoint("one.local"),apps:try apps(),library:try library(),wake:HostWakeTargets(macs:["02:00:00:00:00:01"]))
        let game=try XCTUnwrap(home.games.first { $0.id == "game:steam:570" }),copy=game.copies[0]
        home.toggleFavourite(game.id);home.played(hostID:copy.hostID,app:copy.app)
        home.saveArt(Data([1,2,3]),for:copy)
        let restored=HomeLibrary(defaults:defaults,artRoot:root)
        XCTAssertTrue(restored.games.first { $0.id == game.id }!.favourite)
        XCTAssertNotNil(restored.games.first { $0.id == game.id }?.lastPlayed)
        XCTAssertNil(restored.reach[copy.hostID])
        XCTAssertEqual(restored.cachedArt(copy),Data([1,2,3]))
        XCTAssertEqual(restored.pc(copy.hostID)?.wake.macs.count,1)
        restored.record(host:try info("one"),endpoint:endpoint("one.local"),apps:try apps("Renamed",id:99),library:try library("v2",id:99))
        let updated=try XCTUnwrap(restored.games.first { $0.id == game.id }?.copies[0])
        XCTAssertEqual(updated.id,copy.id,"UUID keeps installation identity after numeric ID changes")
        XCTAssertNil(restored.cachedArt(updated),"Changed cover version must not show old art")
        XCTAssertTrue(restored.games.first { $0.id == game.id }!.favourite)
        XCTAssertNotNil(restored.games.first { $0.id == game.id }?.lastPlayed)
        restored.reconcile([])
        XCTAssertTrue(restored.games.isEmpty)
        XCTAssertTrue(restored.pcs.isEmpty)
    }
    func testFavouriteFollowsInstallationWhenNativeLibraryIsUnavailableAfterHostUpgrade() throws {
        let home=HomeLibrary()
        home.record(host:try info("one"),endpoint:endpoint("one.local"),apps:try apps(),library:try library())
        home.toggleFavourite("game:steam:570")
        home.record(host:try info("one"),endpoint:endpoint("one.local"),apps:try apps(),library:nil)
        XCTAssertTrue(home.games.first { $0.title == "Game" }!.favourite)
        home.record(host:try info("one"),endpoint:endpoint("one.local"),apps:try apps(),library:try library())
        XCTAssertTrue(home.games.first { $0.id == "game:steam:570" }!.favourite)
    }
    func testAliasesDoNotDuplicateAndRemovedPCDoesNotEraseOtherCopy() throws {
        let home=HomeLibrary()
        home.record(host:try info("one"),endpoint:endpoint("old.local"),apps:try apps(),library:try library())
        home.toggleFavourite("game:steam:570")
        home.record(host:try info("one"),endpoint:endpoint("new.local"),apps:try apps(),library:try library())
        XCTAssertEqual(home.pcs.count,1)
        home.record(host:try info("two"),endpoint:endpoint("two.local"),apps:try apps(),library:try library())
        home.reconcile([SavedHost(endpoint:endpoint("two.local"),name:"Two",uniqueID:"two")])
        XCTAssertEqual(home.games.first { $0.id == "game:steam:570" }?.copies.count,1)
        XCTAssertTrue(home.games.first { $0.id == "game:steam:570" }!.favourite)
    }
}

final class WakeWaitTests: XCTestCase {
    func testSendsAtOnceResendsEveryEightSecondsAndGivesUpAfterNinety() {
        let start=ContinuousClock.now
        var wait=WakeWait(start:start)
        XCTAssertEqual(wait.next(online:false,now:start),.send)
        XCTAssertEqual(wait.next(online:false,now:start + .seconds(2)),.wait)
        XCTAssertEqual(wait.next(online:false,now:start + .seconds(8)),.send)
        XCTAssertEqual(wait.next(online:false,now:start + .seconds(15)),.wait)
        XCTAssertEqual(wait.next(online:false,now:start + .seconds(16)),.send)
        XCTAssertEqual(wait.next(online:false,now:start + .seconds(90)),.timedOut)
        XCTAssertEqual(wait.next(online:true,now:start + .seconds(90)),.online,"an answering PC wins in the same tick")
    }
}
