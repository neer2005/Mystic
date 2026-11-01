import Foundation
import CMystic
import MysticCore

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
    public var currentGameUUID: String? = nil
    public var quitAllowed: Bool? = nil
    public var clipboardRead: Bool? = nil
    public var clipboardWrite: Bool? = nil
    /// Whether the host takes a one-time PIN it made itself.
    public var otpPairing: HostFeatureAvailability? = nil
    public var display: HostDisplaySupport? = nil
}
public struct HostApp: Codable, Identifiable, Sendable, Equatable {
    public let id: Int32
    public let name: String
    public let uuid: String
    public let hdrSupported: Bool
}
/// Where a pairing link points. Its PIN and passphrase stay in the link.
public struct PairingLinkTarget: Codable, Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let name: String
    public let uniqueID: String
    public init(host: String,port: UInt16,name: String,uniqueID: String) { self.host=host;self.port=port;self.name=name;self.uniqueID=uniqueID }
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
    public var resumeOnly = false
    public var clipboardSync = false
    /// The PC's speakers keep playing too.
    public var playLocalAudio = false
    /// The PC's displays during this stream; the engine sends each only to hosts that read it.
    public var virtualDisplay = false
    public var hostDisplay = HostDisplayMode.hostDefault
    public var renderScalePercent = 100
    public var displayScalePercent = 0
    /// -1 the host's error correction, -2 automatic, otherwise a percentage; only hosts that
    /// offer client error correction receive it.
    public var fec: Int16 = -1
    /// The route to the host is Wi-Fi; the reply's `clientWireless` says whether to tell it.
    public var clientWireless = false
    /// The display's EDR headroom; hosts other than Rubylight get a luminance estimated from it.
    public var displayHeadroom: Double? = nil
    /// The display's refresh rate x100 (5994 for 59.94 Hz); 0 when unknown. Hosts that read
    /// fractional rates launch at it when it rounds to `fps`.
    public var clientRefreshRateX100: UInt32 = 0
    public init(app: HostApp) { appID = app.id; appUUID = app.uuid }
}
public struct LaunchedStream: Codable, Sendable {
    public let rtspURL: String?
    public let appVersion: String?
    public let codecSupport: UInt32
    public let key: [UInt8]
    public let iv: [UInt8]
    public var runtimeBitrate: Bool? = nil
    public var clipboardRead: Bool? = nil
    public var clipboardWrite: Bool? = nil
    /// The host is told the route is wireless (Rubylight hosts only).
    public var clientWireless: Bool? = nil
    /// The host can send its cursor shapes, if the stream also offers them.
    public var cursorShapes: Bool? = nil
    /// The host takes keyboard layout reports and sends text field notices, if the stream offers them.
    public var keyboardLayout: Bool? = nil
    public var textFields: Bool? = nil
}
/// The host's bitrate controller is on.
public struct HostBitrateStart: Codable, Sendable, Equatable {
    /// Where the controller starts, in kbps; 0 for the stream's bitrate.
    public let initialKbps: UInt32
    public let maxKbps: UInt32
    public init(initialKbps: UInt32,maxKbps: UInt32) { self.initialKbps=initialKbps;self.maxKbps=maxKbps }
}
public struct HostBitrateAction: Codable, Sendable, Equatable {
    /// The bitrate the host moved the stream to, when it moved it.
    public let newKbps: UInt32?
    public let reason: String
    public init(newKbps: UInt32?,reason: String) { self.newKbps=newKbps;self.reason=reason }
}
public struct HostConnectionError: Error, LocalizedError, Sendable {
    public let message: String
    public let retryable: Bool
    public init(_ message: String, retryable: Bool = false) { self.message = message;self.retryable=retryable }
    public var errorDescription: String? { message }
}

extension HostService {
    public func pair(pin: String,passphrase: String) async throws -> PairedHost { throw HostConnectionError("This connection cannot pair with a one-time PIN.") }
    public func pair(link: String) async throws -> PairedHost { throw HostConnectionError("This connection cannot pair with a link.") }
}
public protocol HostService: AnyObject, Sendable {
    func serverInfo() async throws -> HostInfo
    func pair(pin: String) async throws -> PairedHost
    func pair(pin: String,passphrase: String) async throws -> PairedHost
    func pair(link: String) async throws -> PairedHost
    func wakeTargets() async throws -> HostWakeTargets
    func quitApp(expected: HostInfo) async throws
    func apps() async throws -> [HostApp]
    func graphics() async throws -> HostGraphics?
    func writeGraphics(gpu: Int32, setting: String, value: GraphicsValue, expected: HostGraphics, session: HostSession) async throws -> HostGraphics
    func restoreGraphics(expected: HostGraphics, session: HostSession) async throws -> HostGraphics
    func hostSession() async throws -> HostSession?
    func performSessionAction(_ action: HostSessionAction, expected: HostSession) async throws -> HostSession
    func library() async throws -> HostLibrary?
    func artwork(appID: Int32) async throws -> Data
    func launch(_ options: LaunchOptions) async throws -> LaunchedStream
    func setBitrate(kbps: UInt32) async throws -> UInt32
    /// The encoder's live bitrate and whether the host changes it mid-stream.
    func liveBitrate() async throws -> LiveBitrate
    /// Turns a Foundation Sunshine host's own bitrate controller on, up to `maxKbps`; nil when
    /// the host has none.
    func startHostBitrate(maxKbps: UInt32) async throws -> HostBitrateStart?
    func stopHostBitrate() async throws
    /// Reports the network to the host's controller; the answer carries any bitrate it moved to.
    func hostBitrateFeedback(_ feedback: HostBitrateFeedback) async throws -> HostBitrateAction
    /// The host's hardware readings for the performance overlay.
    func hardwareMetrics() async throws -> HostHardware
    /// Android's remote access check; blocks for up to about 20 seconds.
    func remoteCheck(uniqueID: String) async throws -> RemoteCheckResult
    func clipboardText() async throws -> String
    func sendClipboardText(_ text: String) async throws
    /// Permanently cancels this connection, including in-flight pairing and launch requests.
    func cancel()
}

public extension HostService {
    func wakeTargets() async throws -> HostWakeTargets { HostWakeTargets() }
    func quitApp(expected: HostInfo) async throws { throw HostConnectionError("Quitting is unavailable on this host.") }
    func graphics() async throws -> HostGraphics? { nil }
    func writeGraphics(gpu: Int32, setting: String, value: GraphicsValue, expected: HostGraphics, session: HostSession) async throws -> HostGraphics { throw HostConnectionError("Graphics controls are unavailable.") }
    func restoreGraphics(expected: HostGraphics, session: HostSession) async throws -> HostGraphics { throw HostConnectionError("Graphics controls are unavailable.") }
    func hostSession() async throws -> HostSession? { nil }
    func performSessionAction(_ action: HostSessionAction, expected: HostSession) async throws -> HostSession { throw HostConnectionError("Session controls are unavailable on this host.") }
    func library() async throws -> HostLibrary? { nil }
    func artwork(appID: Int32) async throws -> Data { throw HostConnectionError("No artwork available.") }
    func setBitrate(kbps: UInt32) async throws -> UInt32 { throw HostConnectionError("This host does not support live bitrate changes.") }
    func liveBitrate() async throws -> LiveBitrate { LiveBitrate(runtime:false,kbps:0) }
    func startHostBitrate(maxKbps: UInt32) async throws -> HostBitrateStart? { nil }
    func stopHostBitrate() async throws {}
    func hostBitrateFeedback(_ feedback: HostBitrateFeedback) async throws -> HostBitrateAction { throw HostConnectionError("This host runs no bitrate controller.") }
    func hardwareMetrics() async throws -> HostHardware { HostHardware(available:false) }
    func remoteCheck(uniqueID: String) async throws -> RemoteCheckResult { RemoteCheckResult(outcome:.unreachable,error:"Unavailable.") }
    func clipboardText() async throws -> String { throw HostConnectionError("This host does not support clipboard text transfer.") }
    func sendClipboardText(_ text: String) async throws { throw HostConnectionError("This host does not support clipboard text transfer.") }
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
    public static func parsePairingLink(_ link: String) throws -> PairingLinkTarget {
        try decode(mystic_pairing_link_parse(link))
    }
    public static func generateIdentity() throws -> ClientIdentity {
        try decode(mystic_identity_create())
    }
    public func cancel() { mystic_host_cancel(handle) }
    public func serverInfo() async throws -> HostInfo { try await request("info", json: "{}") }
    public func pair(pin: String) async throws -> PairedHost {
        let json = String(decoding: try JSONEncoder().encode(["pin":pin]), as: UTF8.self)
        return try await request("pair", json: json)
    }
    public func pair(pin: String,passphrase: String) async throws -> PairedHost {
        let json = String(decoding: try JSONEncoder().encode(["pin":pin,"passphrase":passphrase]), as: UTF8.self)
        return try await request("pair", json: json)
    }
    public func pair(link: String) async throws -> PairedHost {
        let json = String(decoding: try JSONEncoder().encode(["link":link]), as: UTF8.self)
        return try await request("pairLink", json: json)
    }
    public func wakeTargets() async throws -> HostWakeTargets { try await request("wakeTargets",json:"{}") }
    public func quitApp(expected: HostInfo) async throws {
        struct Request: Encodable { let expectedAppID: Int32;let expectedAppUUID: String }
        struct Response: Decodable, Sendable { let quit: Bool }
        let payload=Request(expectedAppID:expected.currentGame,expectedAppUUID:expected.currentGameUUID ?? "")
        let response: Response = try await request("quit",json:String(decoding:JSONEncoder().encode(payload),as:UTF8.self))
        guard response.quit else { throw HostConnectionError("The host declined to quit the game.") }
    }
    public func apps() async throws -> [HostApp] { try await request("apps", json: "{}") }
    private struct GraphicsResult: Decodable, Sendable { let radeon: HostGraphics? }
    public func graphics() async throws -> HostGraphics? {
        let result: GraphicsResult = try await request("radeon",json:"{}")
        return result.radeon
    }
    private struct GraphicsRequest: Encodable {
        struct Write: Encodable {
            struct Change: Encodable { let id: String;let value: GraphicsValue }
            let gpu: Int32;let changes: [Change]
        }
        let revision: UInt64;let expectedOwner: String;let expectedAppID: Int32?;let write: Write?
    }
    public func writeGraphics(gpu: Int32, setting: String, value: GraphicsValue, expected: HostGraphics, session: HostSession) async throws -> HostGraphics {
        let payload=GraphicsRequest(revision:expected.revision,expectedOwner:session.owner,expectedAppID:session.app?.app_id,write:.init(gpu:gpu,changes:[.init(id:setting,value:value)]))
        return try await graphicsRequest("radeonWrite",payload)
    }
    public func restoreGraphics(expected: HostGraphics, session: HostSession) async throws -> HostGraphics {
        try await graphicsRequest("radeonRestore",GraphicsRequest(revision:expected.revision,expectedOwner:session.owner,expectedAppID:session.app?.app_id,write:nil))
    }
    private func graphicsRequest(_ operation: String,_ payload: GraphicsRequest) async throws -> HostGraphics {
        let result: GraphicsResult = try await request(operation,json:String(decoding:JSONEncoder().encode(payload),as:UTF8.self))
        guard let panel=result.radeon else { throw HostConnectionError("The host returned no graphics settings.") }
        return panel
    }
    public func hostSession() async throws -> HostSession? {
        struct Result: Decodable, Sendable { let session: HostSession? }
        let result: Result = try await request("session",json:"{}")
        return result.session
    }
    public func performSessionAction(_ action: HostSessionAction, expected: HostSession) async throws -> HostSession {
        struct Request: Encodable { let action: String;let expectedAppID: Int32?;let expectedOwner: String }
        struct Result: Decodable, Sendable { let session: HostSession }
        let payload=Request(action:action.rawValue,expectedAppID:expected.app?.app_id,expectedOwner:expected.owner)
        let result: Result = try await request("sessionAction",json:String(decoding:JSONEncoder().encode(payload),as:UTF8.self))
        return result.session
    }
    public func library() async throws -> HostLibrary? {
        // The envelope requires a non-null value; represent unsupported hosts explicitly.
        struct Result: Decodable, Sendable { let library: HostLibrary? }
        let result: Result = try await request("library", json:"{}")
        return result.library
    }
    public func artwork(appID: Int32) async throws -> Data {
        struct Artwork: Decodable, Sendable { let bytes: [UInt8] }
        let result: Artwork = try await request("artwork", json:String(decoding:JSONEncoder().encode(["appID":appID]),as:UTF8.self))
        return Data(result.bytes)
    }
    public func launch(_ options: LaunchOptions) async throws -> LaunchedStream {
        try await request("launch", json: String(decoding: JSONEncoder().encode(options), as: UTF8.self))
    }
    public func hardwareMetrics() async throws -> HostHardware { try await request("hardwareMetrics",json:"{}") }
    public func remoteCheck(uniqueID: String) async throws -> RemoteCheckResult {
        try await request("remoteCheck",json:String(decoding:JSONEncoder().encode(["uniqueID":uniqueID]),as:UTF8.self))
    }
    public func startHostBitrate(maxKbps: UInt32) async throws -> HostBitrateStart? {
        struct Started: Decodable, Sendable { let on: Bool;let initialKbps: UInt32?;let maxKbps: UInt32? }
        let started: Started = try await request("hostBitrateStart",json:String(decoding:JSONEncoder().encode(["maxKbps":maxKbps]),as:UTF8.self))
        return started.on ? HostBitrateStart(initialKbps:started.initialKbps ?? 0,maxKbps:started.maxKbps ?? maxKbps) : nil
    }
    public func stopHostBitrate() async throws {
        struct Stopped: Decodable, Sendable { let on: Bool }
        let _: Stopped = try await request("hostBitrateStop",json:"{}")
    }
    public func hostBitrateFeedback(_ feedback: HostBitrateFeedback) async throws -> HostBitrateAction {
        try await request("hostBitrateFeedback",json:String(decoding:JSONEncoder().encode(feedback),as:UTF8.self))
    }
    public func setBitrate(kbps: UInt32) async throws -> UInt32 {
        struct Applied: Decodable, Sendable { let kbps: UInt32 }
        let applied: Applied = try await request("bitrate",json:String(decoding:JSONEncoder().encode(["kbps":kbps]),as:UTF8.self))
        return applied.kbps
    }
    public func liveBitrate() async throws -> LiveBitrate {
        try await request("liveBitrate",json:"{}")
    }
    public func clipboardText() async throws -> String {
        struct Copy: Decodable, Sendable { let text: String }
        let result: Copy = try await request("clipboardRead",json:"{}")
        try ClipboardText.validate(result.text,limit:ClipboardText.manualLimit)
        return result.text
    }
    public func sendClipboardText(_ text: String) async throws {
        try ClipboardText.validate(text,limit:ClipboardText.manualLimit)
        struct Sent: Decodable, Sendable { let sent: Bool }
        let result: Sent = try await request("clipboardWrite",json:String(decoding:JSONEncoder().encode(["text":text]),as:UTF8.self))
        guard result.sent else { throw HostConnectionError("The host did not accept clipboard text.") }
    }
    private func request<T: Decodable & Sendable>(_ operation: String, json: String) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try Self.decode(mystic_host_request(handle, operation, json))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let value: T?; let error: String?;let retryable: Bool? }
    private static func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let pointer else { throw HostConnectionError("The engine returned no response.") }
        defer { mystic_string_free(pointer) }
        let bytes = Data(bytes: pointer, count: strlen(pointer))
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: bytes)
        guard envelope.ok, let result = envelope.value else {
            throw HostConnectionError(envelope.error ?? "The host request failed.",retryable:envelope.retryable ?? false)
        }
        return result
    }
}
