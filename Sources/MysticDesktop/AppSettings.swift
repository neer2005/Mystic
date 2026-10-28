import Foundation
import Observation
import MysticCore

@MainActor
public protocol AppSettingsStorage {
    func load() -> Data?
    func save(_ data: Data)
}

@MainActor
public final class SettingsPreferences: AppSettingsStorage {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults=defaults }
    public func load() -> Data? { defaults.data(forKey:"streamPreferences.v1") }
    public func save(_ data: Data) { defaults.set(data,forKey:"streamPreferences.v1") }
}

@MainActor @Observable
public final class AppSettings {
    public private(set) var value=StreamPreferences()
    public private(set) var error: String?
    @ObservationIgnored private let storage: (any AppSettingsStorage)?
    private struct Document: Codable { let version: Int;let preferences: StreamPreferences }
    public init(storage: (any AppSettingsStorage)? = SettingsPreferences()) {
        self.storage=storage
        guard let data=storage?.load() else { return }
        do {
            guard data.count <= 65_536 else { throw SettingsError.invalidDocument }
            let document=try JSONDecoder().decode(Document.self,from:data)
            guard document.version == 1 else { throw SettingsError.invalidDocument }
            value=document.preferences.validated()
        } catch { self.error="Saved settings could not be read. Default settings are in use." }
    }
    public func update(_ change: (inout StreamPreferences) -> Void) {
        var next=value;change(&next);next=next.validated()
        guard next != value else { return }
        value=next;persist()
    }
    public func restoreDefaults() {
        let pane=value.settingsPane
        value=StreamPreferences();value.settingsPane=pane;persist()
    }
    private func persist() {
        do { storage?.save(try JSONEncoder().encode(Document(version:1,preferences:value)));error=nil }
        catch { self.error="Settings could not be saved." }
    }
    private enum SettingsError: Error { case invalidDocument }
}
