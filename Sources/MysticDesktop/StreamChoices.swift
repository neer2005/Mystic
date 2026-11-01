import Foundation
import Observation
import MysticCore

/// A small preferences document in UserDefaults, read once and written on every change.
@MainActor @Observable
public final class PreferenceDocument<Value: Codable & Equatable> {
    public private(set) var value: Value
    public private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let key: String
    init(_ initial: Value,key: String,defaults: UserDefaults?) {
        self.value=initial;self.key=key;self.defaults=defaults
        guard let data=defaults?.data(forKey:key) else { return }
        do {
            guard data.count <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
            value=try JSONDecoder().decode(Value.self,from:data)
        } catch { self.error="Saved choices could not be read; defaults are in use." }
    }
    /// Applies a change; a throwing change leaves everything as it was and says why.
    @discardableResult
    public func update(_ change: (inout Value) throws -> Void) -> Bool {
        var next=value
        do { try change(&next) } catch { self.error="\(error)";return false }
        error=nil
        guard next != value else { return true }
        value=next
        if let data=try? JSONEncoder().encode(next) { defaults?.set(data,forKey:key) }
        return true
    }
}

extension ConnectionModel {
    /// The network profile this stream would use, from the route found at connect.
    public var activeNetworkProfile: NetworkProfiles.Profile? { networkProfiles.value.selected(networkKind) }
    /// Whether the selected game quits on the PC when its stream is left.
    public var quitsOnLeave: Bool {
        get {
            guard let host=hostProfileKey,let game=gameProfileKey else { return false }
            return quitOnLeave.value.quits(host:host,game:game)
        }
        set {
            guard let host=hostProfileKey,let game=gameProfileKey else { return }
            quitOnLeave.update { $0.set(newValue,host:host,game:game) }
        }
    }
    /// The settings a launch would use: the global, host and game settings, then the network profile.
    public var launchVideoSettings: StreamVideoSettings {
        activeNetworkProfile.map { $0.overrides.apply(to:effectiveVideoSettings) } ?? effectiveVideoSettings
    }
}
