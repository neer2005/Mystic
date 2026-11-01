import Foundation
import CMystic

/// The engine's network figures for one stats tick, for the overlay.
public struct NetworkMeasures: Decodable, Sendable, Equatable {
    public let rttMs: Double?
    public let rttVarianceMs: Double?
    public let lossPercent: Double?
    public let jitterMs: Double?
    public let receivedFps: Double?
    public let poorConnection: Bool
    /// The network is silent and input is being held until the host answers.
    public let inputHeld: Bool
}

/// Nightjar's stream doctor report over the last 30 seconds (`nightjar_policy::health::Report`).
public struct StreamHealthReport: Decodable, Sendable, Equatable {
    public enum Finding: String, Decodable, Sendable { case network="NETWORK",decoder="DECODER",host="HOST",presentation="PRESENTATION",heat="HEAT",periodic="PERIODIC",bursts="BURSTS" }
    public enum Offer: String, Decodable, Sendable { case none,tryLower="try",undo }
    public let findings: [Finding]
    public let samples: Int
    public let recent: Bool
    /// The worst values among the counted samples, or -1.
    public let worstLossPercent: Double
    public let worstDecodeMs: Double
    public let worstHostP95Ms: Double
    public let worstDisplayP95Ms: Double
    public let stalls: Int
    public let stallPeriodMs: UInt64
    public let hostIncludesSend: Bool
    public let lateSamples: Int
    public let offer: Offer
}

/// Why a bitrate trial step left the bitrate alone.
public enum TrialRefusal: Error, Sendable, Equatable {
    /// The host reported no live encoder bitrate; the trial is kept.
    case unavailable
    /// The encoder already runs at the trial's 500 kbps floor; the trial is dropped.
    case minimum
    /// Something else changed the bitrate since the trial; the trial is dropped.
    case replaced
}

/// The host's live encoder bitrate, the only baseline a trial may start from.
public struct LiveBitrate: Decodable, Sendable, Equatable {
    public let runtime: Bool
    public let kbps: UInt32
    public init(runtime: Bool,kbps: UInt32) { self.runtime=runtime;self.kbps=kbps }
}

extension StreamingEngine {
    /// One stats tick; timings in milliseconds, NaN when unknown. Serialized with the session.
    public func healthTick(decodeMs: Float,hostP95Ms: Float,displayP95Ms: Float,releasedFps: Float,shownFps: Float,
                           thermalLevel: UInt32,intervalMs: UInt32,nowMillis: UInt64) throws -> NetworkMeasures {
        try Self.decode(mystic_session_health_tick(clipboardHandle,decodeMs,hostP95Ms,displayP95Ms,releasedFps,shownFps,thermalLevel,intervalMs,nowMillis))
    }
    public func healthReport(nowMillis: UInt64,currentKbps: UInt32,runtimeBitrate: Bool,automatic: Bool,busy: Bool) throws -> StreamHealthReport {
        try Self.decode(mystic_session_health_report(clipboardHandle,nowMillis,currentKbps,runtimeBitrate,automatic,busy))
    }
    /// The bitrate a trial step asks for, or why it is refused.
    public func trialBegin(undo: Bool,liveKbps: UInt32) -> Result<UInt32,TrialRefusal> {
        switch mystic_session_trial_begin(clipboardHandle,undo,liveKbps) {
        case -2: .failure(.minimum)
        case -3: .failure(.replaced)
        case let kbps where kbps > 0: .success(UInt32(clamping:kbps))
        default: .failure(.unavailable)
        }
    }
    public func trialApplied(undo: Bool,previousKbps: UInt32,appliedKbps: UInt32) {
        mystic_session_trial_applied(clipboardHandle,undo,previousKbps,appliedKbps)
    }
    public func trialClear() { mystic_session_trial_clear(clipboardHandle) }

    /// Starts automatic quality at the negotiated size and rate. False when the host takes no
    /// size changes; throws for an invalid mode or stream.
    public func qualityBegin(mode: UInt8,minShortEdge: UInt32,minFps: UInt32,nowMillis: UInt64) throws -> Bool {
        let result=mystic_session_quality_begin(clipboardHandle,mode,minShortEdge,minFps,nowMillis)
        if result == MYSTIC_ERR_UNIMPLEMENTED { return false }
        guard result == MYSTIC_OK else { throw HostConnectionError("Automatic quality could not start (\(result)).") }
        return true
    }
    /// One tick after the health tick, with the latest decoded picture's size.
    public func qualityTick(decodedWidth: UInt32,decodedHeight: UInt32,suspended: Bool,nowMillis: UInt64) throws -> QualityTick {
        try Self.decode(mystic_session_quality_tick(clipboardHandle,decodedWidth,decodedHeight,suspended,nowMillis))
    }
    public func qualityEnd() { mystic_session_quality_end(clipboardHandle) }

    private static func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) throws -> T {
        guard let pointer else { throw HostConnectionError("No stream health response.") }
        defer { mystic_string_free(pointer) }
        let result=try JSONDecoder().decode(HealthEnvelope<T>.self,from:Data(bytes:pointer,count:strlen(pointer)))
        guard result.ok,let value=result.value else { throw HostConnectionError(result.error ?? "Stream health failed.") }
        return value
    }
}

private struct HealthEnvelope<T: Decodable>: Decodable { let ok: Bool;let value: T?;let error: String? }

/// What one automatic quality tick did.
public struct QualityTick: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable { case off,hold,requested,confirmed,stopped }
    public let state: State
    public let width: UInt32?
    public let height: UInt32?
    public let fpsMilliHz: UInt32?
    public let reason: String?
    public init(state: State,width: UInt32? = nil,height: UInt32? = nil,fpsMilliHz: UInt32? = nil,reason: String? = nil) {
        self.state=state;self.width=width;self.height=height;self.fpsMilliHz=fpsMilliHz;self.reason=reason
    }
}
