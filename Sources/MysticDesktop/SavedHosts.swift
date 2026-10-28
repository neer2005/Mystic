import Foundation
import Observation
import MysticCore

@MainActor
public protocol HostPreferencesStorage {
    func load() -> Data?
    func save(_ data: Data)
    var legacyEndpoint: HostEndpoint? { get }
}

@MainActor
public final class HostPreferences: HostPreferencesStorage {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults=defaults }
    public func load() -> Data? { defaults.data(forKey:"savedHosts.v1") }
    public func save(_ data: Data) { defaults.set(data,forKey:"savedHosts.v1") }
    public var legacyEndpoint: HostEndpoint? {
        guard let address=defaults.string(forKey:"lastHost") else { return nil }
        return HostEndpoint(address:address,port:UInt16(defaults.string(forKey:"lastPort") ?? "47989") ?? 0)
    }
}

@MainActor @Observable
public final class SavedHosts {
    public private(set) var catalog=HostCatalog()
    public private(set) var error: String?
    public var hosts: [SavedHost] { catalog.hosts }
    @ObservationIgnored private let storage: (any HostPreferencesStorage)?
    public init(storage: (any HostPreferencesStorage)? = HostPreferences()) {
        self.storage=storage
        guard let storage else { return }
        if let data=storage.load() {
            do { catalog=try HostCatalog(data:data) }
            catch { self.error="Saved hosts could not be read. Manual connections are still available." }
        } else if let endpoint=storage.legacyEndpoint {
            catalog.remember(endpoint:endpoint,name:endpoint.address,uniqueID:nil,at:nil)
            persist()
        }
    }
    func remember(endpoint: HostEndpoint,name: String,uniqueID: String?) {
        catalog.remember(endpoint:endpoint,name:name,uniqueID:uniqueID);persist()
    }
    public func remove(_ endpoint: HostEndpoint) { catalog.remove(endpoint);persist() }
    private func persist() {
        do { storage?.save(try catalog.encoded());error=nil }
        catch { self.error="Saved hosts could not be written. Manual connections are still available." }
    }
}
