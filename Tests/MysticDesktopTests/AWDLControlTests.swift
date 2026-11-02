import XCTest
@testable import MysticDesktop

@MainActor
final class AWDLControlTests: XCTestCase {
    private final class Fake: AWDLHelperService {
        var status: AWDLControl.Status = .ready
        var holds: [Bool]=[]
        var registered=0,unregistered=0
        func register() throws { registered+=1 }
        func unregister() async throws { unregistered+=1 }
        func openApproval() {}
        func setHeld(_ held: Bool) { holds.append(held) }
    }
    func testItHoldsOnlyDuringAStreamOverWiFiAndLetsGoAfter() {
        let fake=Fake(),control=AWDLControl(service:fake)
        control.setEnabled(true);XCTAssertEqual(fake.registered,1);XCTAssertEqual(fake.holds,[])
        control.update(streaming:true);XCTAssertEqual(fake.holds,[true],"An unknown route counts as Wi-Fi")
        control.update(routeWireless:true);XCTAssertEqual(fake.holds,[true])
        control.update(routeWireless:false);XCTAssertEqual(fake.holds,[true,false],"Ethernet keeps AirDrop")
        control.update(routeWireless:true);XCTAssertEqual(fake.holds,[true,false,true])
        control.update(streaming:false);XCTAssertEqual(fake.holds,[true,false,true,false])
    }
    func testItDoesNothingUntilApproved() {
        let fake=Fake(),control=AWDLControl(service:fake)
        fake.status = .needsApproval
        control.setEnabled(true);control.update(streaming:true)
        XCTAssertEqual(control.status,.needsApproval);XCTAssertEqual(fake.holds,[])
        fake.status = .ready;control.refresh()
        XCTAssertEqual(fake.holds,[true])
    }
    func testTurningItOffDuringAStreamLetsGoAndRemovesTheHelper() async {
        let fake=Fake(),control=AWDLControl(service:fake)
        control.setEnabled(true);control.update(streaming:true)
        control.setEnabled(false)
        XCTAssertEqual(fake.holds,[true,false]);XCTAssertEqual(control.status,.off)
        for _ in 0..<50 where fake.unregistered == 0 { await Task.yield() }
        XCTAssertEqual(fake.unregistered,1)
    }
}
