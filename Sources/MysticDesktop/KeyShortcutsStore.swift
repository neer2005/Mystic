import Foundation
import Observation
import MysticCore

/// The saved key shortcuts, kept in Android's file format (`KeyShortcuts`) so a file exported
/// here imports into Nightjar or Moonlight on Android, and the other way round.
@MainActor @Observable
public final class KeyShortcutsStore {
    public private(set) var shortcuts=KeyShortcuts()
    /// Why the last change, import or load failed; cleared by the next success.
    public private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults?
    static let key="keyShortcuts.v1"
    public init(defaults: UserDefaults? = .standard) {
        self.defaults=defaults
        guard let data=defaults?.data(forKey:Self.key) else { return }
        do { shortcuts=try KeyShortcuts.parse(data) }
        catch { self.error="Saved shortcuts could not be read. \(error)" }
    }
    @discardableResult
    public func save(id: String? = nil,name: String,chord: String) -> Bool {
        change { try $0.save(id:id,name:name,chord:chord) }
    }
    public func remove(id: String) { change { $0.remove(id:id) } }
    /// Replaces every shortcut with the file's; an invalid file changes nothing.
    @discardableResult
    public func importFile(_ url: URL) -> Bool {
        change { shortcuts in
            let handle=try FileHandle(forReadingFrom:url)
            defer { try? handle.close() }
            shortcuts=try KeyShortcuts.parse(handle.readData(ofLength:KeyShortcuts.maxBytes+1))
        }
    }
    public func exportFile(_ url: URL) -> Bool {
        do { try shortcuts.encoded().write(to:url,options:.atomic);error=nil;return true }
        catch { self.error="Could not export shortcuts: \(error.localizedDescription)";return false }
    }
    private func change(_ edit: (inout KeyShortcuts) throws -> Void) -> Bool {
        var next=shortcuts
        do { try edit(&next) } catch { self.error="\(error)";return false }
        shortcuts=next;error=nil
        defaults?.set(next.encoded(),forKey:Self.key)
        return true
    }
}
