import Foundation
import Network
import Darwin

/// What carries traffic over one interface, for Nightjar's link hints.
enum NetworkMedium: Equatable, Sendable {
    case wired(linkMbps: Int32)
    case wireless
    /// Tunnels (such as Tailscale), loopback and anything else that does not say.
    case other
}

/// How this Mac reaches a host: whether the route is wireless and, when wired, its link speed.
/// As in Nightjar's desktop client, the interface toward the host decides; a tunnel defers to
/// the Mac's internet connection, so a VPN over Wi-Fi still counts as Wi-Fi.
struct NetworkRoute: Equatable, Sendable {
    var wireless: Bool
    /// Mbit/s on a wired route; 0 on a wireless one or when the port does not report it.
    var linkMbps: Int32
    /// "route" or "internet connection", for the session log.
    var source: String

    static func resolve(route: NetworkMedium?,connection: NetworkMedium?) -> NetworkRoute? {
        func from(_ medium: NetworkMedium?,_ source: String) -> NetworkRoute? {
            switch medium {
            case .wired(let mbps): NetworkRoute(wireless:false,linkMbps:max(0,mbps),source:source)
            case .wireless: NetworkRoute(wireless:true,linkMbps:0,source:source)
            case .other,nil: nil
            }
        }
        return from(route,"route") ?? from(connection,"internet connection")
    }
    /// What a launch tells the host, given the user's choices. Unknown routes tell nothing.
    static func hints(_ route: NetworkRoute?,tellWireless: Bool,tellLinkSpeed: Bool) -> (wireless: Bool,linkMbps: Int32) {
        guard let route else { return (false,0) }
        return (tellWireless && route.wireless,tellLinkSpeed && !route.wireless ? route.linkMbps : 0)
    }
    var summary: String {
        wireless ? "Wi-Fi (\(source))" : (linkMbps > 0 ? "wired, \(linkMbps) Mbit/s (\(source))" : "wired (\(source))")
    }

    /// What `toward` found: the hints, and whether the route runs over a VPN.
    struct Report: Sendable {
        var route: NetworkRoute?
        /// As Nightjar: a VPN route streams as remote with 1024-byte packets, since a tunnel's
        /// smaller MTU (WireGuard's 1420, Tailscale's 1280) would fragment every 1392-byte one.
        var vpn: Bool
        var interface: String?
        /// The Mac's internet connection bills by data or saves data (an iPhone hotspot).
        var metered=false
    }

    /// Looks up the route toward `host`, giving up after `timeout`. Sends nothing: a UDP
    /// connection becomes ready once the system has chosen its interface.
    static func toward(host: String,port: UInt16,timeout: Duration = .seconds(1)) async -> Report {
        async let route=routeInterface(host:host,port:port,timeout:timeout)
        async let connection=connectionMedium(timeout:timeout)
        let interface=await route,(internet,metered)=await connection
        return Report(route:resolve(route:interface.flatMap(medium),connection:internet),
                      vpn:interface.map { isVPN(name:$0.name,type:$0.type,mtu:linkMTU($0.name)) } ?? false,
                      interface:interface?.name,metered:metered)
    }

    private static func routeInterface(host: String,port: UInt16,timeout: Duration) async -> NWInterface? {
        guard let port=NWEndpoint.Port(rawValue:port) else { return nil }
        let connection=NWConnection(host:NWEndpoint.Host(host),port:port,using:.udp)
        let once=Once<NWInterface?>()
        let interface=await withCheckedContinuation { continuation in
            once.set(continuation)
            connection.stateUpdateHandler={ state in
                switch state {
                case .ready: once.finish(connection.currentPath?.availableInterfaces.first)
                case .failed,.cancelled: once.finish(nil)
                default: break
                }
            }
            connection.start(queue:.global(qos:.userInitiated))
            Task { try? await Task.sleep(for:timeout);once.finish(nil) }
        }
        connection.cancel()
        return interface
    }
    /// Moonlight's VPN heuristics, as Nightjar's desktop client applies them, in macOS terms:
    /// a tunnel or PPP interface (utun carries WireGuard, Tailscale and the system VPNs; ipsec,
    /// ppp, tun and tap; ZeroTier's feth and zt), or an MTU under 1500.
    static func isVPN(name: String,type: NWInterface.InterfaceType,mtu: Int) -> Bool {
        guard type != .loopback else { return false }
        let tunnels=["utun","ipsec","ppp","tun","tap","zt","feth","wg"]
        return tunnels.contains { name.hasPrefix($0) } || (1..<1500).contains(mtu)
    }
    private static func connectionMedium(timeout: Duration) async -> (NetworkMedium?,Bool) {
        let monitor=NWPathMonitor()
        let once=Once<(NetworkMedium?,Bool)>()
        let medium=await withCheckedContinuation { continuation in
            once.set(continuation)
            monitor.pathUpdateHandler={ path in
                once.finish(path.status == .satisfied ? (medium(path),path.isExpensive || path.isConstrained) : (nil,false))
            }
            monitor.start(queue:.global(qos:.userInitiated))
            Task { try? await Task.sleep(for:timeout);once.finish((nil,false)) }
        }
        monitor.cancel()
        return medium
    }
    private static func medium(_ path: NWPath) -> NetworkMedium? {
        path.availableInterfaces.first.flatMap(medium)
    }
    private static func medium(_ interface: NWInterface) -> NetworkMedium? {
        switch interface.type {
        case .wifi,.cellular: return .wireless
        case .wiredEthernet: return .wired(linkMbps:linkMbps(interface.name))
        default: return .other
        }
    }
    /// The port's negotiated speed, which macOS reports in bits per second on the link entry.
    static func linkMbps(_ name: String) -> Int32 {
        linkData(name).map { Int32(min(9999,UInt64($0.ifi_baudrate)/1_000_000)) } ?? 0
    }
    /// The interface's MTU, or 0 when it has no link entry.
    static func linkMTU(_ name: String) -> Int {
        linkData(name).map { Int($0.ifi_mtu) } ?? 0
    }
    private static func linkData(_ name: String) -> if_data? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var entry=list
        while let current=entry?.pointee {
            if String(cString:current.ifa_name) == name,current.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),let data=current.ifa_data {
                return data.assumingMemoryBound(to:if_data.self).pointee
            }
            entry=current.ifa_next
        }
        return nil
    }
}

/// Resumes a continuation exactly once, from whichever callback or timeout comes first.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Value,Never>?
    private var pending: Value?
    private var done=false
    func set(_ continuation: CheckedContinuation<Value,Never>) {
        lock.lock()
        if done,let pending { lock.unlock();continuation.resume(returning:pending);return }
        self.continuation=continuation;lock.unlock()
    }
    func finish(_ value: Value) {
        lock.lock()
        guard !done else { lock.unlock();return }
        done=true
        guard let continuation else { pending=value;lock.unlock();return }
        self.continuation=nil;lock.unlock()
        continuation.resume(returning:value)
    }
}
