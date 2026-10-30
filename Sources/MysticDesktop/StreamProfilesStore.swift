import Foundation
import Observation
import MysticCore

@MainActor
public final class StreamProfilePreferences: AppSettingsStorage {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults=defaults }
    public func load() -> Data? { defaults.data(forKey:"streamProfiles.v1") }
    public func save(_ data: Data) { defaults.set(data,forKey:"streamProfiles.v1") }
}

@MainActor @Observable
public final class StreamProfilesStore {
    public private(set) var value=StreamProfileCatalog()
    public private(set) var error: String?
    @ObservationIgnored private let storage: (any AppSettingsStorage)?
    public init(storage: (any AppSettingsStorage)? = StreamProfilePreferences()) {
        self.storage=storage
        guard let data=storage?.load() else { return }
        do { value=try StreamProfileCatalog(data:data) }
        catch { self.error="Saved stream profiles could not be read. Global defaults are in use." }
    }
    public func update(_ change: (inout StreamProfileCatalog) throws -> Void) {
        do {
            var next=value;try change(&next)
            let data=try next.encoded()
            storage?.save(data);value=next;error=nil
        } catch StreamProfileCatalog.ProfileError.capacity {
            error="The saved profile limit has been reached. Reset an unused profile before adding another."
        } catch { self.error="Stream profile settings could not be saved." }
    }
}
