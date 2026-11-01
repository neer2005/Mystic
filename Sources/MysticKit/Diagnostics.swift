import Foundation
import CMystic

/// The performance overlay's Compact mark, by Nightjar's shared thresholds.
public enum OverlayHealth: UInt8, Sendable {
    case unknown, good, fair, poor
    /// A dot while the stream is fine, a triangle or a cross when not, so the shape says it too.
    public var glyph: String { switch self { case .fair: "▲";case .poor: "✕";default: "●" } }
    public static func of(shownFps: Double?,receivedFps: Double?,networkMs: Double?,lossPercent: Double?,decodeMs: Double?) -> Self {
        func f(_ value: Double?) -> Float { value.map(Float.init) ?? .nan }
        return Self(rawValue:mystic_overlay_health(f(shownFps),f(receivedFps),f(networkMs),f(lossPercent),f(decodeMs))) ?? .unknown
    }
}

/// When to ask the host for its hardware readings, and how long one shows: Nightjar's shared
/// `HardwarePoll`. Calls belong to one owner (the app's main actor).
public final class HardwarePoll {
    public enum Answer: Sendable { case sample(sampledAtUnixMs: Int64,intervalMs: UInt32),failed,unavailable }
    private let handle: OpaquePointer
    public init() { handle=mystic_hardware_poll_new()! }
    deinit { mystic_hardware_poll_free(handle) }
    /// The request to send now, as its generation. `wanted`: the overlay shows host readings.
    public func due(nowMillis: UInt64,wanted: Bool) -> UInt32? {
        let generation=mystic_hardware_poll_due(handle,nowMillis,wanted)
        return generation < 0 ? nil : UInt32(generation)
    }
    /// Whether to show the answer's sample.
    public func answered(generation: UInt32,nowMillis: UInt64,_ answer: Answer) -> Bool {
        switch answer {
        case let .sample(at,interval): mystic_hardware_poll_answered(handle,generation,nowMillis,0,at,interval)
        case .failed: mystic_hardware_poll_answered(handle,generation,nowMillis,1,0,0)
        case .unavailable: mystic_hardware_poll_answered(handle,generation,nowMillis,2,0,0)
        }
    }
    public func fresh(nowMillis: UInt64) -> Bool { mystic_hardware_poll_fresh(handle,nowMillis) }
}

/// Nightjar's redaction for log lines: PC names and addresses added as secrets, IDs, keys, PINs.
public enum Redaction {
    public static func addSecret(_ secret: String) { if !secret.isEmpty { mystic_redact_add_secret(secret) } }
    public static func scrub(_ line: String) -> String {
        guard let pointer=mystic_redact(line) else { return "" }
        defer { mystic_string_free(pointer) }
        return String(cString:pointer)
    }
}

/// The host's CPU and GPU readings (`/api/hardware-metrics`); `available` false where it offers none.
public struct HostHardware: Decodable, Sendable, Equatable {
    public struct GPU: Decodable, Sendable, Equatable {
        public let id: Int
        public let name: String
        public let metrics: [String:Double]
    }
    public let available: Bool
    public var sampledAtUnixMs: Int64? = nil
    public var intervalMs: UInt32? = nil
    public var cpu: [String:Double]? = nil
    public var gpus: [GPU]? = nil
    public init(available: Bool) { self.available=available }
}

/// Android's remote access check: whether this address reaches the paired PC, and how.
public struct RemoteCheckResult: Decodable, Sendable, Equatable {
    public enum Outcome: String, Decodable, Sendable { case verified,wrongHost,pairRevoked,permissionDenied,unreachable,notPaired,cancelled }
    public enum Path: String, Decodable, Sendable { case direct,relay,peerRelay,unknown,none="" }
    public struct Stats: Decodable, Sendable, Equatable { public let latencyMs: Double?;public let jitterMs: Double?;public let lossPercent: Double? }
    public let outcome: Outcome
    public var path: Path? = nil
    public var error: String? = nil
    public var stats: Stats? = nil
}
