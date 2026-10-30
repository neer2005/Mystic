import Foundation
import CMystic

public enum ClipboardText {
    public static let manualLimit=Int(MYSTIC_CLIPBOARD_MANUAL_MAX_BYTES)
    public static let syncLimit=Int(MYSTIC_CLIPBOARD_SYNC_MAX_BYTES)
    public static func validate(_ text: String,limit: Int) throws {
        guard text.utf8.count <= limit else { throw HostConnectionError("Clipboard text is too large.") }
        guard !text.contains("\0") else { throw HostConnectionError("Clipboard text contains an unsupported NUL character.") }
    }
}
public struct ClipboardSyncResult: Codable, Sendable, Equatable {
    public let available: Bool
    public let text: String?
    public init(available: Bool,text: String?) { self.available=available;self.text=text }
}

extension StreamingEngine {
    /// Owning worker only; the control stream uses Nightjar's shared echo and baseline rules.
    public func clipboardStep(active: Bool,baseline: Bool,text: String?) throws -> ClipboardSyncResult {
        if let text { try ClipboardText.validate(text,limit:ClipboardText.syncLimit) }
        struct Request: Encodable { let active: Bool;let baseline: Bool;let text: String? }
        let request=String(decoding:try JSONEncoder().encode(Request(active:active,baseline:baseline,text:text)),as:UTF8.self)
        guard let pointer=mystic_session_clipboard_step(clipboardHandle,request) else { throw HostConnectionError("The engine returned no clipboard response.") }
        defer { mystic_string_free(pointer) }
        struct Envelope: Decodable { let ok: Bool;let value: ClipboardSyncResult?;let error: String? }
        let result=try JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer)))
        guard result.ok,let value=result.value else { throw HostConnectionError(result.error ?? "Clipboard sync failed.") }
        if let text=value.text { try ClipboardText.validate(text,limit:ClipboardText.syncLimit) }
        return value
    }
}
