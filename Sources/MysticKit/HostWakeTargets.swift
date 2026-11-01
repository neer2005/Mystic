import Foundation
import Darwin
import CMystic

public struct HostWakeTargets: Codable, Sendable {
    public let macs: [String]
    public let broadcasts: [String]
    public init(macs: [String] = [],broadcasts: [String] = []) { self.macs=Array(macs.prefix(8));self.broadcasts=Array(broadcasts.prefix(16)) }
    /// Sends Nightjar's wake plan: every MAC to the PC, 255.255.255.255 and the subnet
    /// broadcasts of the PC and of this Mac, on the classic and Moonlight ports for `port`, and
    /// to `ff02::1` on each of this Mac's IPv6 links.
    public func send(to host: String,port: UInt16 = 47989) async throws -> Int {
        let targets=self
        return try await Task.detached {
            struct Request: Encodable {
                let host: String;let port: UInt16;let macs: [String];let broadcasts: [String]
                let localBroadcasts: [String];let ipv6Scopes: [UInt32]
            }
            struct Value: Decodable { let sent: Int }
            struct Envelope: Decodable { let ok: Bool;let value: Value?;let error: String? }
            let links=Self.localLinks()
            let request=Request(host:host,port:port,macs:targets.macs,broadcasts:targets.broadcasts,
                                localBroadcasts:links.broadcasts,ipv6Scopes:links.ipv6Scopes)
            let json=String(decoding:try JSONEncoder().encode(request),as:UTF8.self)
            guard let pointer=mystic_wake(json) else { throw HostConnectionError("No wake response.") }
            defer { mystic_string_free(pointer) }
            let result=try JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer)))
            guard result.ok,let sent=result.value?.sent else { throw HostConnectionError(result.error ?? "Wake failed.") }
            return sent
        }.value
    }
    /// This Mac's side of a wake: the subnet broadcast of each running IPv4 interface, and the
    /// index of each running IPv6 one. Loopback is left out.
    static func localLinks() -> (broadcasts: [String],ipv6Scopes: [UInt32]) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return ([],[]) }
        defer { freeifaddrs(list) }
        var broadcasts: [String]=[],scopes: [UInt32]=[]
        var entry=list
        while let current=entry?.pointee {
            defer { entry=current.ifa_next }
            let flags=Int32(current.ifa_flags)
            guard flags & IFF_UP != 0,flags & IFF_RUNNING != 0,flags & IFF_LOOPBACK == 0,let address=current.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET where flags & IFF_BROADCAST != 0:
                // BSD keeps the broadcast address in the destination field.
                guard let broadcast=current.ifa_dstaddr else { continue }
                var text=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
                var ip=broadcast.withMemoryRebound(to:sockaddr_in.self,capacity:1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET,&ip,&text,socklen_t(text.count)) != nil else { continue }
                let value=String(decoding:text.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
                if !broadcasts.contains(value),broadcasts.count < 16 { broadcasts.append(value) }
            case AF_INET6:
                let index=if_nametoindex(current.ifa_name)
                if index != 0,!scopes.contains(index),scopes.count < 16 { scopes.append(index) }
            default: break
            }
        }
        return (broadcasts,scopes)
    }
}
