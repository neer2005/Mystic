import Foundation
import CMystic

public struct ClientIdentity: Codable, Sendable, Equatable {
    public let uniqueID: String
    public let certificate: String
    public let privateKey: String
}
public struct HostInfo: Codable, Sendable, Equatable {
    public let name: String
    public let uniqueID: String
    public let paired: Bool
    public let appVersion: String?
    public let codecSupport: UInt32
    public let currentGame: Int32
}
public struct HostApp: Codable, Identifiable, Sendable, Equatable {
    public let id: Int32
    public let name: String
    public let uuid: String
    public let hdrSupported: Bool
}
public struct PairedHost: Codable, Sendable {
    public let certificate: String
    public let uniqueID: String
}
public struct LaunchOptions: Codable, Sendable {
    public var appID: Int32
    public var appUUID: String
    public var width: UInt32 = 1920
    public var height: UInt32 = 1080
    public var fps: UInt32 = 60
    public var hdr = false
    public var channelCount: UInt8 = 2
    public var channelMask: UInt16 = 3
    public var gamepadMask: UInt16 = 0
    public init(app: HostApp) { appID = app.id; appUUID = app.uuid }
}
public struct LaunchedStream: Codable, Sendable {
    public let rtspURL: String?
    public let appVersion: String?
    public let codecSupport: UInt32
    public let key: [UInt8]
    public let iv: [UInt8]
}
public struct HostConnectionError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol HostService: AnyObject, Sendable {
    func serverInfo() async throws -> HostInfo
    func pair(pin: String) async throws -> PairedHost
    func apps() async throws -> [HostApp]
    func launch(_ options: LaunchOptions) async throws -> LaunchedStream
    /// Permanently cancels this connection, including in-flight pairing and launch requests.
    func cancel()
}

/// A worker queue owns blocking Nightjar calls. Cancellation is the sole concurrent operation.
public final class HostConnection: HostService, @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "Mystic.HostHTTP")
    public init(address: String, port: UInt16 = 47989, identity: ClientIdentity, certificate: String? = nil) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("/"), !address.contains("\0"), port != 0 else {
            throw HostConnectionError("Enter a host name or IP address and a port from 1 to 65535.")
        }
        let json = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        var error = [CChar](repeating: 0, count: 4096)
        guard let handle = mystic_host_new(address, port, json, certificate, &error, error.count) else {
            throw HostConnectionError(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        self.handle = handle
    }
    deinit { mystic_host_free(handle) }
    public static func generateIdentity() throws -> ClientIdentity {
        try decode(mystic_identity_create())
    }
    public func cancel() { mystic_host_cancel(handle) }
    public func serverInfo() async throws -> HostInfo { try await request("info", json: "{}") }
    public func pair(pin: String) async throws -> PairedHost {
        let json = String(decoding: try JSONEncoder().encode(["pin":pin]), as: UTF8.self)
        return try await request("pair", json: json)
    }
    public func apps() async throws -> [HostApp] { try await request("apps", json: "{}") }
    public func launch(_ options: LaunchOptions) async throws -> LaunchedStream {
        try await request("launch", json: String(decoding: JSONEncoder().encode(options), as: UTF8.self))
    }
    private func request<T: Decodable & Sendable>(_ operation: String, json: String) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try Self.decode(mystic_host_request(handle, operation, json))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let value: T?; let error: String? }
    private static func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let pointer else { throw HostConnectionError("The engine returned no response.") }
        defer { mystic_string_free(pointer) }
        let bytes = Data(bytes: pointer, count: strlen(pointer))
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: bytes)
        guard envelope.ok, let result = envelope.value else {
            throw HostConnectionError(envelope.error ?? "The host request failed.")
        }
        return result
    }
}
