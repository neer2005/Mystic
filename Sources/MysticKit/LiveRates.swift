import Foundation
import CMystic

public struct LiveRates: Decodable, Sendable {
    public let available: Bool
    public let pending: Bool
    public let result: Result?
    public let error: String?
    public struct Result: Decodable, Sendable {
        public let kbps: UInt32
        public let fpsMilliHz: UInt32
        public let bitrateStatus: UInt8
        public let bitrateReason: UInt8
        public let fpsStatus: UInt8
        public let fpsReason: UInt8
        public var summary: String {
            "Bitrate: \(Self.outcome(bitrateStatus,bitrateReason)); frame rate: \(Self.outcome(fpsStatus,fpsReason))."
        }
        private static func outcome(_ status: UInt8,_ reason: UInt8) -> String {
            let text: String
            switch status { case 0:return "unchanged";case 1:return "applied";case 2:text="limited";default:text="refused" }
            let detail: String
            switch reason { case 1:detail="invalid value";case 2:detail="disabled on host";case 3:detail="codec limitation";case 4:detail="host limit";case 5:detail="encoder limit";case 6:detail="encoder failed";case 7:detail="superseded";default:detail="host decision" }
            return text+" ("+detail+")"
        }
    }
}
extension StreamingEngine {
    public func liveRates(kbps: UInt32 = 0,fpsMilliHz: UInt32 = 0) throws -> LiveRates {
        guard let pointer=mystic_session_rates(clipboardHandle,kbps,fpsMilliHz) else { throw HostConnectionError("No rate-control response.") }
        defer { mystic_string_free(pointer) }
        struct Envelope: Decodable { let ok: Bool;let value: LiveRates?;let error: String? }
        let result=try JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer)))
        guard result.ok,let value=result.value else { throw HostConnectionError(result.error ?? "Rate control failed.") }
        return value
    }
}
