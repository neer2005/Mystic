import XCTest
import MysticCore
import MysticKit
@testable import MysticDesktop

@MainActor
final class ShortcutLaunchTests: XCTestCase {
    func testNightjarsCommandLineInBothSpellings() {
        XCTAssertEqual(ShortcutLaunch.parse(arguments:[]),.none)
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["--host","Big Dawg","--app=Steam","--quit-on-exit"]),
                       .launch(ShortcutLaunch(host:"Big Dawg",app:"Steam",quitOnExit:true)))
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["--host=host1"]),.launch(ShortcutLaunch(host:"host1")))
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["--version"]),.version)
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["-h"]),.help)
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["--help"]),.help)
    }
    func testMacOSArgumentsAreSkippedAndMistakesAreUsageErrors() {
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["-NSDocumentRevisionsDebugMode","YES","-psn_0_12345"]),.none)
        XCTAssertEqual(ShortcutLaunch.parse(arguments:["-NSDocumentRevisionsDebugMode","YES","--host","pc"]),.launch(ShortcutLaunch(host:"pc")))
        for arguments in [["--host"],["--host","--app","x"],["--host","a","--host","b"],["--app","Steam"],["--quit-on-exit"],
                          ["--host","pc","--fullscreen"],["--host","pc","stray"],["--host="],["--version=2"]] {
            guard case .invalid(let message)=ShortcutLaunch.parse(arguments:arguments) else { XCTFail("\(arguments)");continue }
            XCTAssertTrue(message.hasSuffix(ShortcutLaunch.usage),"\(arguments): \(message)")
        }
    }
    func testLinksRoundTripAndForeignURLsAreIgnored() throws {
        let launch=ShortcutLaunch(host:"Big Dawg",app:"Halo: MCC & Co",quitOnExit:true)
        XCTAssertEqual(launch.link.absoluteString,"mystic://stream?host=Big%20Dawg&app=Halo:%20MCC%20%26%20Co&quit-on-exit=1")
        var back=try XCTUnwrap(ShortcutLaunch.parse(url:launch.link))
        XCTAssertTrue(back.fromLink);back.fromLink=false
        XCTAssertEqual(back,launch)
        XCTAssertEqual(ShortcutLaunch.parse(url:URL(string:"MYSTIC://Stream?host=pc")!),ShortcutLaunch(host:"pc",fromLink:true))
        for text in ["mystic://stream","mystic://stream?app=x","mystic://stream?host=%20","mystic://pair?host=pc","https://stream?host=pc"] {
            XCTAssertNil(ShortcutLaunch.parse(url:URL(string:text)!),text)
        }
    }
    func testCommandLinesAreQuotedForTheShell() {
        let launch=ShortcutLaunch(host:"Ann's PC",app:"Desktop",quitOnExit:true)
        XCTAssertEqual(launch.commandLine(executable:"/Applications/Mystic.app/Contents/MacOS/MysticApp"),
                       "'/Applications/Mystic.app/Contents/MacOS/MysticApp' --host 'Ann'\\''s PC' --app 'Desktop' --quit-on-exit")
    }
    func testSavedPCsMatchByIDAddressOrUniqueName() throws {
        let a=SavedHost(endpoint:try XCTUnwrap(HostEndpoint(address:"10.0.0.2",port:47989)),name:"Gaming PC",uniqueID:"AAAA")
        let b=SavedHost(endpoint:try XCTUnwrap(HostEndpoint(address:"10.0.0.3",port:47989)),name:"gaming pc",uniqueID:"BBBB")
        let c=SavedHost(endpoint:try XCTUnwrap(HostEndpoint(address:"office.local",port:47989)),name:"Office")
        let hosts=[a,b,c]
        func found(_ query: String) -> String? { if case .found(let host)=ConnectionModel.match(query,in:hosts) { return host.name };return nil }
        XCTAssertEqual(found("bbbb"),"gaming pc")
        XCTAssertEqual(found("10.0.0.2"),"Gaming PC")
        XCTAssertEqual(found("office.local:47989"),"Office")
        XCTAssertEqual(found("OFFICE"),"Office")
        guard case .ambiguous=ConnectionModel.match("Gaming PC",in:hosts) else { return XCTFail("two PCs share the name") }
        guard case .none=ConnectionModel.match("Laptop",in:hosts) else { return XCTFail("no such PC") }
    }
    func testAppsMatchByIDThenUniqueName() throws {
        let apps: [HostApp]=try JSONDecoder().decode([HostApp].self,from:Data("""
            [{"id":1,"name":"Desktop","uuid":"D1","hdrSupported":false},{"id":2,"name":"Steam","uuid":"","hdrSupported":false},
             {"id":3,"name":"steam","uuid":"S3","hdrSupported":false}]
            """.utf8))
        guard case .found(let desktop)=ConnectionModel.match("desktop",in:apps),desktop.id == 1 else { return XCTFail("by name") }
        guard case .found(let byID)=ConnectionModel.match("s3",in:apps),byID.id == 3 else { return XCTFail("by ID") }
        guard case .ambiguous=ConnectionModel.match("Steam",in:apps) else { return XCTFail("two apps share the name") }
        guard case .none=ConnectionModel.match("",in:apps) else { return XCTFail("an empty ID matches nothing") }
    }
}
