import Foundation
import XCTest
import MysticCore
@testable import MysticDesktop

@MainActor
final class KeyShortcutsStoreTests: XCTestCase {
    func testShortcutsPersistImportAndExport() throws {
        let suite="mystic.tests.shortcuts.\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let store=KeyShortcutsStore(defaults:defaults)
        XCTAssertTrue(store.save(name:"Lock",chord:"WIN + L"))
        XCTAssertFalse(store.save(name:"Bad",chord:"WIN + NOPE"))
        XCTAssertEqual(store.error,"Unsupported key: NOPE")
        XCTAssertEqual(KeyShortcutsStore(defaults:defaults).shortcuts.data.map(\.chord),["WIN + L"],"kept across launches")
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(suite,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let exported=folder.appendingPathComponent("out.json")
        XCTAssertTrue(store.exportFile(exported))
        let android=folder.appendingPathComponent("android.json")
        try Data(#"{"version":1,"data":[{"id":"a1","name":"Task view","keys":["KEYCODE_META_LEFT","KEYCODE_TAB"]}]}"#.utf8).write(to:android)
        XCTAssertTrue(store.importFile(android))
        XCTAssertEqual(store.shortcuts.data.map(\.chord),["WIN + TAB"],"an import replaces every shortcut")
        let broken=folder.appendingPathComponent("broken.json")
        try Data("{}".utf8).write(to:broken)
        XCTAssertFalse(store.importFile(broken));XCTAssertEqual(store.shortcuts.data.count,1)
        XCTAssertTrue(store.importFile(exported));XCTAssertEqual(store.shortcuts.data.map(\.name),["Lock"])
        defaults.set(Data("junk".utf8),forKey:KeyShortcutsStore.key)
        let unreadable=KeyShortcutsStore(defaults:defaults)
        XCTAssertTrue(unreadable.shortcuts.data.isEmpty);XCTAssertNotNil(unreadable.error)
    }
}
