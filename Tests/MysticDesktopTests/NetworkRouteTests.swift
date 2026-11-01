import XCTest
import Darwin
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
    func testTunnelsPPPAndSmallMTUsAreVPNsAsInNightjar() {
        for name in ["utun4","ipsec0","ppp0","tun1","tap0","zt3jnwghuq","feth2341","wg0"] {
            XCTAssertTrue(NetworkRoute.isVPN(name:name,type:.other,mtu:1500),name)
        }
        XCTAssertTrue(NetworkRoute.isVPN(name:"en7",type:.wiredEthernet,mtu:1420),"an MTU under 1500 is a tunnel's")
        XCTAssertFalse(NetworkRoute.isVPN(name:"en0",type:.wifi,mtu:1500))
        XCTAssertFalse(NetworkRoute.isVPN(name:"en5",type:.wiredEthernet,mtu:9000),"jumbo frames are not a tunnel")
        XCTAssertFalse(NetworkRoute.isVPN(name:"en1",type:.wiredEthernet,mtu:0),"an unknown MTU decides nothing")
        XCTAssertFalse(NetworkRoute.isVPN(name:"lo0",type:.loopback,mtu:1280))
        XCTAssertEqual(NetworkRoute.linkMTU("no-such-interface0"),0)
    }
    func testLinkWatchReportsALossOnceAndOnlyAddressChanges() {
        var watch=LinkWatch(.init(local:"192.168.1.20",metered:false))
        XCTAssertNil(watch.event(.init(local:"192.168.1.20",metered:true)),"new metering on the same network is no change")
        XCTAssertEqual(watch.event(.init(local:"10.0.0.5",metered:false)),.changed(metered:false,afterLoss:false))
        XCTAssertEqual(watch.event(nil),.lost)
        XCTAssertNil(watch.event(nil),"the loss is reported once")
        XCTAssertEqual(watch.event(.init(local:"10.0.0.5",metered:true)),.changed(metered:true,afterLoss:true),
                       "the same address back still ends the loss")
        XCTAssertNil(watch.event(.init(local:"10.0.0.5",metered:true)))
    }
    func testLocalAddressTowardLoopbackIsLoopback() throws {
        var remote=sockaddr_in()
        remote.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);remote.sin_family=sa_family_t(AF_INET)
        remote.sin_port=UInt16(47989).bigEndian;remote.sin_addr.s_addr=inet_addr("127.0.0.1")
        var storage=sockaddr_storage()
        withUnsafeMutableBytes(of:&storage) { target in withUnsafeBytes(of:remote) { target.copyMemory(from:$0) } }
        XCTAssertEqual(NetworkWatch.localAddress(toward:storage),"127.0.0.1")
    }
}
