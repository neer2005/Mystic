import Carbon
import Foundation
import MysticCore

/// The Mac's current keyboard layout for the host, and a watch on the user switching it, as
/// Nightjar's desktop client reports it at the start and on every keymap change.
@MainActor
final class KeyboardLayoutWatch {
    private var observer: (any NSObjectProtocol)?
    /// The layout keys type with now; nil when macOS names none Mystic can report.
    static func current() -> KeyboardLayoutReport? {
        guard let source=TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id=property(source,kTISPropertyInputSourceID) as? String else { return nil }
        return KeyboardLayoutReport.mac(inputSourceID:id,languages:property(source,kTISPropertyInputSourceLanguages) as? [String] ?? [])
    }
    private static func property(_ source: TISInputSource,_ key: CFString) -> AnyObject? {
        TISGetInputSourceProperty(source,key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }
    init(changed: @escaping @MainActor () -> Void) {
        observer=DistributedNotificationCenter.default().addObserver(
            forName:Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),object:nil,queue:.main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }
    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer=nil
    }
    isolated deinit { stop() }
}
