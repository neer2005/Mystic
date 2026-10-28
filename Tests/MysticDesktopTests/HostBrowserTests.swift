import XCTest
import Foundation
import MysticCore
@testable import MysticDesktop

@MainActor
final class HostBrowserTests: XCTestCase {
    func testLegacyMigrationRemovalAndPersistence() throws {
        let storage=MemoryHostPreferences()
        storage.legacyEndpoint=HostEndpoint(address:"100.66.0.33",port:47989)
        let library=SavedHosts(storage:storage)
        let endpoint=try XCTUnwrap(storage.legacyEndpoint)
        XCTAssertEqual(library.hosts.first?.endpoint,endpoint)
        XCTAssertNil(library.hosts.first?.uniqueID)
        library.remember(endpoint:endpoint,name:"Big Dawg",uniqueID:"host1")
        let restarted=SavedHosts(storage:storage)
        XCTAssertEqual(restarted.hosts.first?.name,"Big Dawg")
        restarted.remove(endpoint)
        XCTAssertTrue(SavedHosts(storage:storage).hosts.isEmpty) // No remigration after removal.
    }
    func testCorruptPreferencesDoNotBlockManualRecovery() throws {
        let storage=MemoryHostPreferences();storage.data=Data("not JSON".utf8)
        let library=SavedHosts(storage:storage)
        XCTAssertNotNil(library.error);XCTAssertTrue(library.hosts.isEmpty)
        let endpoint=try XCTUnwrap(HostEndpoint(address:"pc.local",port:47989))
        library.remember(endpoint:endpoint,name:"PC",uniqueID:nil)
        XCTAssertNil(library.error)
        XCTAssertEqual(SavedHosts(storage:storage).hosts.count,1)
    }
    func testDiscoveryDeduplicatesSortsBoundsAndRejectsLateUpdates() throws {
        let transport=FakeDiscovery(),discovery=HostDiscovery(transport:FakeDiscovery())
        discovery.start();discovery.stop() // Starting/stopping with no announcements is harmless.
        let model=HostDiscovery(transport:transport)
        model.start();model.start();XCTAssertEqual(transport.starts,1)
        let one=try XCTUnwrap(HostEndpoint(address:"one.local",port:47989))
        let two=try XCTUnwrap(HostEndpoint(address:"two.local",port:48000))
        let oldUpdate=try XCTUnwrap(transport.update),oldStatus=try XCTUnwrap(transport.status)
        oldUpdate([DiscoveredHost(endpoint:two,name:"Z"),DiscoveredHost(endpoint:one,name:"A"),DiscoveredHost(endpoint:one,name:"A")])
        XCTAssertEqual(model.hosts.map(\.endpoint),[one,two])
        oldUpdate([]);XCTAssertTrue(model.hosts.isEmpty) // Service removal.
        model.refresh();XCTAssertEqual(transport.starts,2)
        oldUpdate([DiscoveredHost(endpoint:one,name:"Stale")]);oldStatus("Stale")
        XCTAssertTrue(model.hosts.isEmpty);XCTAssertNotEqual(model.status,"Stale")
        transport.update?((0..<80).map { DiscoveredHost(endpoint:HostEndpoint(address:"pc\($0).local",port:47989)!,name:"PC \($0)") })
        XCTAssertEqual(model.hosts.count,64)
        let current=try XCTUnwrap(transport.update)
        model.stop();current([DiscoveredHost(endpoint:one,name:"Late")])
        XCTAssertTrue(model.hosts.isEmpty);XCTAssertFalse(model.isRunning)
    }
}

@MainActor
final class MemoryHostPreferences: HostPreferencesStorage {
    var data: Data?
    var legacyEndpoint: HostEndpoint?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data=data }
}

@MainActor
private final class FakeDiscovery: HostDiscoveryTransport {
    var starts=0
    var update: (@MainActor ([DiscoveredHost]) -> Void)?
    var status: (@MainActor (String) -> Void)?
    func start(update: @escaping @MainActor ([DiscoveredHost]) -> Void,status: @escaping @MainActor (String) -> Void) {
        starts+=1;self.update=update;self.status=status
    }
    func stop() {}
}
