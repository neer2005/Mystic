import Testing
import Foundation
import CMystic
@testable import MysticKit

struct HostConnectionTests {
    @Test func launchCredentialsMapExactly() throws {
        var config = StreamConfiguration()
        config.remoteInputAESKey = Array(1...16)
        config.remoteInputAESIV = Array(101...116)
        config.encryptionFlags = 0x1234
        var c = try config.cConfiguration()
        #expect(withUnsafeBytes(of: &c.remote_input_aes_key) { Array($0) } == Array(1...16))
        #expect(withUnsafeBytes(of: &c.remote_input_aes_iv) { Array($0) } == Array(101...116))
        #expect(c.encryption_flags == 0x1234)
        config.remoteInputAESKey = [1]
        #expect(throws: EngineError.self) { _ = try config.cConfiguration() }
    }
    @Test func hostIdentityAndValidation() throws {
        let identity = try HostConnection.generateIdentity()
        let roundTrip = try JSONDecoder().decode(ClientIdentity.self, from: JSONEncoder().encode(identity))
        #expect(identity == roundTrip)
        #expect(identity.certificate.contains("BEGIN CERTIFICATE"))
        let host = try HostConnection(address: "127.0.0.1", identity: identity)
        host.cancel() // cancellation before any request must be safe
        #expect(throws: HostConnectionError.self) { _ = try HostConnection(address: "", identity: identity) }
        #expect(throws: HostConnectionError.self) { _ = try HostConnection(address: "https://host", identity: identity) }
        #expect(throws: HostConnectionError.self) { _ = try HostConnection(address: "host", port: 0, identity: identity) }
    }
}
