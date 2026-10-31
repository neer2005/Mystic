import Foundation
import CMystic

public struct HostWakeTargets: Codable, Sendable {
    public let macs: [String]
    public let broadcasts: [String]
    public init(macs: [String] = [],broadcasts: [String] = []) { self.macs=Array(macs.prefix(8));self.broadcasts=Array(broadcasts.prefix(16)) }
    public func send(to host: String) async throws -> Int {
        let targets=self
        return try await Task.detached {
            struct Request: Encodable { let host: String;let macs: [String];let broadcasts: [String] }
            struct Value: Decodable { let sent: Int }
            struct Envelope: Decodable { let ok: Bool;let value: Value?;let error: String? }
            let json=String(decoding:try JSONEncoder().encode(Request(host:host,macs:targets.macs,broadcasts:targets.broadcasts)),as:UTF8.self)
            guard let pointer=mystic_wake(json) else { throw HostConnectionError("No wake response.") }
            defer { mystic_string_free(pointer) }
            let result=try JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer)))
            guard result.ok,let sent=result.value?.sent else { throw HostConnectionError(result.error ?? "Wake failed.") }
            return sent
        }.value
    }
}
