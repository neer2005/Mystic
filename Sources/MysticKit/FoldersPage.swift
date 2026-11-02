import Foundation
import CMystic

/// A host's shared folders as the engine last described them.
public struct FoldersSnapshot: Decodable, Sendable, Equatable {
    public struct Folder: Decodable, Sendable, Equatable, Identifiable {
        public let id: String,name: String,writable: Bool
    }
    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let name: String,directory: Bool,size: UInt64,modifiedMs: UInt64
        public var id: String { name }
    }
    public struct Transfer: Decodable, Sendable, Equatable {
        public let upload: Bool,name: String,done: UInt64,total: UInt64
    }
    public let refusal: String?,folder: Folder?,path: String,loading: Bool
    public let error: String?,transferError: String?,done: String?
    public let folders: [Folder],entries: [Entry]?,transfer: Transfer?
}
public protocol FoldersPage: AnyObject, Sendable {
    func request(_ operation: String,_ body: [String:any Sendable]) throws -> FoldersSnapshot
}
/// Requests only touch the engine's state, never the PC, so they are safe on the main actor.
final class HostFoldersPage: FoldersPage, @unchecked Sendable {
    private struct Envelope: Decodable { let ok: Bool;let value: FoldersSnapshot?;let error: String? }
    private let handle: OpaquePointer
    private let host: AnyObject
    init?(host handle: OpaquePointer,keeping host: AnyObject) {
        guard let page=mystic_folders_new(handle) else { return nil }
        self.handle=page;self.host=host
    }
    deinit { mystic_folders_free(handle) }
    func request(_ operation: String,_ body: [String:any Sendable]) throws -> FoldersSnapshot {
        let json=String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)
        guard let pointer=mystic_folders_request(handle,operation,json) else { throw HostConnectionError("The engine returned no response.") }
        defer { mystic_string_free(pointer) }
        let envelope=try JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer)))
        guard envelope.ok,let value=envelope.value else { throw HostConnectionError(envelope.error ?? "The shared folders request failed.") }
        return value
    }
}
