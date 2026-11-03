#if canImport(ObjectiveC)
import Foundation
#endif

/// Holding Apple Wireless Direct Link down during a stream: AirDrop's Wi-Fi link hops channels,
/// which can stall a stream's packets. After AWDL Control by James Howard (MIT).
public enum AWDLHold {
    /// The privileged helper's launchd service, which is also its Mach service.
    public static let helperLabel="com.mystic.streaming.awdl"
    public static let helperPlist="\(helperLabel).plist"
    public static let appIdentifier="com.mystic.streaming"
    public static let interface="awdl0"
    private static let up: Int32=0x1 // IFF_UP, the same on every BSD.

    /// An unknown route counts as Wi-Fi: holding it costs AirDrop for a stream, and not holding it can cost the stream.
    public static func shouldHold(enabled: Bool,streaming: Bool,routeWireless: Bool?) -> Bool {
        enabled && streaming && routeWireless != false
    }
    /// The flags to set on the interface, or nil when it is already as wanted.
    public static func flags(current: Int32,held: Bool) -> Int32? {
        if held { return current & up != 0 ? current & ~up : nil }
        return current & up != 0 ? nil : current | up
    }
    /// Only this team's Mystic may tell the root helper what to do.
    public static func clientRequirement(team: String) -> String {
        "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}

#if canImport(ObjectiveC)
/// All the helper can do. A connection that ends, however it ends, lets AWDL back up.
@objc(MysticAWDLHelperProtocol)
public protocol AWDLHelperProtocol {
    func setHeld(_ held: Bool)
}
#endif
