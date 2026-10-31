import XCTest
@testable import MysticKit

final class HostLibraryTests: XCTestCase {
    func testNativeMetadataPreservesLaunchIdentityAndAddsInstalledGames() throws {
        let library=try JSONDecoder().decode(HostLibrary.self,from:Data(#"""
        {"revision":"v1","games":[
          {"install_id":"a","app_id":1,"title":"New title","store":{"source":"steam","name":"Steam"},"installed":true,"running":true,"artwork":{"cover":"https://untrusted.invalid/image","version":"2"}},
          {"install_id":"b","app_id":2,"title":"New game","store":null,"installed":null,"running":false,"artwork":{"cover":null,"version":""}},
          {"install_id":"c","app_id":3,"title":"Uninstalled","installed":false,"running":false,"artwork":{"cover":null,"version":""}},
          {"install_id":"a","app_id":1,"title":"Duplicate","running":false,"artwork":{"version":""}}
        ]}
        """#.utf8))
        let apps=[HostApp(id:1,name:"Old title",uuid:"stable-uuid",hdrSupported:true),HostApp(id:4,name:"Desktop",uuid:"desktop",hdrSupported:true)]
        let merged=library.merging(apps:apps)
        XCTAssertEqual(merged.map(\.id),[1,4,2])
        XCTAssertEqual(merged[0].name,"New title")
        XCTAssertEqual(merged[0].uuid,"stable-uuid")
        XCTAssertTrue(merged[0].hdrSupported)
        XCTAssertEqual(library.game(appID:1)?.store?.name,"Steam")
        XCTAssertNil(library.game(appID:3))
        XCTAssertEqual(LaunchOptions(app:merged[0]).appUUID,"stable-uuid")
    }
}
