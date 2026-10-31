import XCTest
@testable import MysticDesktop

final class NetworkRouteTests: XCTestCase {
    func testRouteToHostDecidesAndTunnelsDeferToTheInternetConnection() {
        XCTAssertEqual(NetworkRoute.resolve(route:.wired(linkMbps:2500),connection:.wireless),
                       NetworkRoute(wireless:false,linkMbps:2500,source:"route"),"A PC on the local Ethernet is wired even when Wi-Fi is the default")
        XCTAssertEqual(NetworkRoute.resolve(route:.other,connection:.wireless),
                       NetworkRoute(wireless:true,linkMbps:0,source:"internet connection"),"A VPN over Wi-Fi counts as Wi-Fi")
        XCTAssertEqual(NetworkRoute.resolve(route:nil,connection:.wired(linkMbps:1000))?.linkMbps,1000)
        XCTAssertNil(NetworkRoute.resolve(route:.other,connection:.other))
    }
    func testHintsFollowTheSettingsAndNeverSendAWirelessLinkSpeed() {
        let wired=NetworkRoute(wireless:false,linkMbps:2500,source:"route"),wifi=NetworkRoute(wireless:true,linkMbps:0,source:"route")
        XCTAssertTrue(NetworkRoute.hints(wired,tellWireless:true,tellLinkSpeed:true) == (false,2500))
        XCTAssertTrue(NetworkRoute.hints(wired,tellWireless:true,tellLinkSpeed:false) == (false,0))
        XCTAssertTrue(NetworkRoute.hints(wifi,tellWireless:true,tellLinkSpeed:true) == (true,0))
        XCTAssertTrue(NetworkRoute.hints(wifi,tellWireless:false,tellLinkSpeed:true) == (false,0))
        XCTAssertTrue(NetworkRoute.hints(nil,tellWireless:true,tellLinkSpeed:true) == (false,0),"An unknown route tells nothing")
    }
    func testLinkSpeedOfAMissingInterfaceIsUnknown() {
        XCTAssertEqual(NetworkRoute.linkMbps("no-such-interface0"),0)
    }
}
