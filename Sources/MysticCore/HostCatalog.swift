public import Foundation

/// An HTTP control endpoint, also the existing Keychain pin lookup key.
public struct HostEndpoint: Codable, Hashable, Sendable, Identifiable {
    public let address: String
    public let port: UInt16
    public var id: String { "\(address):\(port)" }
    public init?(address: String,port: UInt16) {
        let address=address.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard !address.isEmpty,address.utf8.count <= 253,port != 0,
              !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !address.contains(where: { "/\\?#@[]".contains($0) }),
              !address.contains(":") || address.filter({ $0 == ":" }).count >= 2 else { return nil }
        self.address=address;self.port=port
    }
    private enum CodingKeys: CodingKey { case address,port }
    public init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let address=try c.decode(String.self,forKey:.address),port=try c.decode(UInt16.self,forKey:.port)
        guard let endpoint=Self(address:address,port:port) else {
            throw DecodingError.dataCorruptedError(forKey:.address,in:c,debugDescription:"Invalid host endpoint")
        }
        self=endpoint
    }
}

public struct SavedHost: Codable, Equatable, Sendable, Identifiable {
    public let endpoint: HostEndpoint
    public let name: String
    /// Metadata only. Never used to select or copy a certificate to another endpoint.
    public let uniqueID: String?
    public let lastConnected: Date?
    public var id: String { endpoint.id }
    public init(endpoint: HostEndpoint,name: String,uniqueID: String? = nil,lastConnected: Date? = nil) {
        self.endpoint=endpoint
        let name=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(256))
        self.name=name.isEmpty ? endpoint.address : name
        self.uniqueID=uniqueID.map { String($0.prefix(256)) };self.lastConnected=lastConnected
    }
}

/// Versioned, bounded preference data; no identity, certificate or launch secrets.
public struct HostCatalog: Sendable {
    public private(set) var hosts: [SavedHost] = []
    public static let capacity=32
    public init() {}
    private struct Document: Codable { let version: Int; let hosts: [SavedHost] }
    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw CatalogError.invalidDocument }
        let document=try JSONDecoder().decode(Document.self,from:data)
        guard document.version == 1 else { throw CatalogError.invalidDocument }
        // Revalidate names and duplicate endpoints even for hand-edited preferences.
        for host in document.hosts.prefix(Self.capacity).reversed() {
            remember(endpoint:host.endpoint,name:host.name,uniqueID:host.uniqueID,at:host.lastConnected)
        }
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(Document(version:1,hosts:hosts)) }
    public mutating func remember(endpoint: HostEndpoint,name: String,uniqueID: String?,at date: Date? = Date()) {
        hosts.removeAll { $0.endpoint == endpoint }
        hosts.insert(SavedHost(endpoint:endpoint,name:name,uniqueID:uniqueID,lastConnected:date),at:0)
        if hosts.count > Self.capacity { hosts.removeLast(hosts.count-Self.capacity) }
    }
    public mutating func remove(_ endpoint: HostEndpoint) { hosts.removeAll { $0.endpoint == endpoint } }
    public enum CatalogError: Error { case invalidDocument }
}

public struct DiscoveredHost: Equatable, Sendable, Identifiable {
    public let endpoint: HostEndpoint
    public let name: String
    public var id: String { endpoint.id }
    public init(endpoint: HostEndpoint,name: String) { self.endpoint=endpoint;self.name=String(name.prefix(256)) }
}
