import Foundation
import CMystic

/// A host's Files page as the engine last described it.
public struct FilesSnapshot: Decodable, Sendable, Equatable {
    public struct RemoteFile: Decodable, Sendable, Equatable, Identifiable {
        public let name: String,size: UInt64,modifiedMs: UInt64
        public var id: String { name }
        public init(name: String,size: UInt64,modifiedMs: UInt64) { self.name=name;self.size=size;self.modifiedMs=modifiedMs }
    }
    public struct Folder: Decodable, Sendable, Equatable {
        public let folder: String,freeBytes: UInt64,maxFileBytes: UInt64,files: [RemoteFile]
    }
    public struct Transfer: Decodable, Sendable, Equatable, Identifiable {
        public let id: UInt64,upload: Bool,title: String,status: String
        public let fraction: Double?,finished: Bool,cancelling: Bool,failed: Bool,canRetry: Bool
        public let savedName: String?,detail: String?
    }
    /// "checking", "known" or "failed".
    public let access: String
    public let mayUpload: Bool,mayDownload: Bool
    public let uploadRefusal: String?,downloadRefusal: String?,accessError: String?
    public let list: Folder?,listError: String?,listing: Bool,active: Bool
    public let downloads: String,notices: [String],transfers: [Transfer]
}
public protocol FilesPage: AnyObject, Sendable {
    func snapshot() throws -> FilesSnapshot
    func checkAgain() throws -> FilesSnapshot
    func refresh() throws -> FilesSnapshot
    func send(_ files: [URL]) throws -> FilesSnapshot
    func download(name: String,size: UInt64) throws -> FilesSnapshot
    func cancel(_ id: UInt64) throws -> FilesSnapshot
    func retry(_ id: UInt64) throws -> FilesSnapshot
    func clearFinished() throws -> FilesSnapshot
}
/// Requests only touch the engine's list, never the PC, so they are safe on the main actor.
final class HostFilesPage: FilesPage, @unchecked Sendable {
    private struct Envelope: Decodable { let ok: Bool;let value: FilesSnapshot?;let error: String? }
    private let handle: OpaquePointer
    private let host: AnyObject
    init?(host handle: OpaquePointer,downloads: URL,keeping host: AnyObject) {
        guard let page=mystic_files_new(handle,downloads.path) else { return nil }
        self.handle=page;self.host=host
    }
    deinit { mystic_files_free(handle) }
    private func request(_ operation: String,_ body: [String:Any] = [:]) throws -> FilesSnapshot {
        let json=String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self)
        guard let pointer=mystic_files_request(handle,operation,json) else { throw HostConnectionError("The engine returned no response.") }
        defer { mystic_string_free(pointer) }
        let envelope=try JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer)))
        guard envelope.ok,let value=envelope.value else { throw HostConnectionError(envelope.error ?? "The Files request failed.") }
        return value
    }
    func snapshot() throws -> FilesSnapshot { try request("snapshot") }
    func checkAgain() throws -> FilesSnapshot { try request("checkAgain") }
    func refresh() throws -> FilesSnapshot { try request("refresh") }
    func send(_ files: [URL]) throws -> FilesSnapshot { try request("send",["paths":files.map(\.path)]) }
    func download(name: String,size: UInt64) throws -> FilesSnapshot { try request("download",["name":name,"size":size]) }
    func cancel(_ id: UInt64) throws -> FilesSnapshot { try request("cancel",["id":id]) }
    func retry(_ id: UInt64) throws -> FilesSnapshot { try request("retry",["id":id]) }
    func clearFinished() throws -> FilesSnapshot { try request("clearFinished") }
}
