import XCTest
import Foundation
import MysticKit
@testable import MysticDesktop

@MainActor
final class ConnectionModelTests: XCTestCase {
    func testPairedHostLoadsApplications() async throws {
        let mock = MockHost(paired: true)
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false, makeHost: { _, _, _, _ in mock })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect()
        try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.host?.name, "Test Host")
        XCTAssertEqual(model.apps.first?.name, "Desktop")
        model.disconnect()
        XCTAssertEqual(model.phase, .idle)
    }
    func testPairingPersistsPinAndLoadsApps() async throws {
        let mock = MockHost(paired: false), vault = MemoryVault()
        let model = ConnectionModel(vault: vault, rememberHost: false, makeHost: { _, _, _, _ in mock })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        XCTAssertEqual(model.host?.paired, false)
        model.pair()
        XCTAssertEqual(model.pairingPIN?.count, 4)
        try await settle(model)
        XCTAssertEqual(model.host?.paired, true)
        XCTAssertEqual(try vault.certificate(for: "127.0.0.1:47989"), "pinned certificate")
        XCTAssertEqual(model.apps.count, 1)
        XCTAssertNil(model.pairingPIN)
    }
    func testLaunchFailureKeepsLibraryAvailableForRetry() async throws {
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false, makeHost: { _, _, _, _ in MockHost(paired: true) })
        await model.prepare()
        guard model.capabilities?.supportedFormats ?? 0 != 0 else { throw XCTSkip("No hardware decoder available") }
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        model.play(); try await settle(model)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.errorMessage, "not used")
        XCTAssertTrue(model.canPlay)
        XCTAssertEqual(model.apps.count, 1)
    }
    func testDisconnectIgnoresLateResponse() async throws {
        let mock = MockHost(paired: true, delay: true)
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false, makeHost: { _, _, _, _ in mock })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect()
        try await Task.sleep(for: .milliseconds(30))
        model.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.host); XCTAssertTrue(model.apps.isEmpty)
    }
    func testCredentialFailureIsVisible() async throws {
        let model = ConnectionModel(vault: MemoryVault(failSave: true), rememberHost: false, makeHost: { _, _, _, _ in MockHost(paired: false) })
        model.address = "127.0.0.1"; model.port = "47989"
        model.connect(); try await settle(model)
        model.pair(); try await settle(model)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.errorMessage?.contains("Keychain") == true)
        XCTAssertTrue(model.apps.isEmpty)
    }
    func testInvalidAddressAndPort() {
        let model = ConnectionModel(vault: MemoryVault(), rememberHost: false)
        model.address = "https://host"; model.connect()
        XCTAssertEqual(model.phase, .failed)
        model.address = "host"; model.port = "65536"; model.connect()
        XCTAssertEqual(model.phase, .failed)
    }
    private func settle(_ model: ConnectionModel) async throws {
        for _ in 0..<200 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Host operation did not finish")
    }
}

private final class MockHost: HostService, @unchecked Sendable {
    let lock = NSLock()
    private var paired: Bool
    let delay: Bool
    init(paired: Bool, delay: Bool = false) { self.paired = paired; self.delay = delay }
    func serverInfo() async throws -> HostInfo {
        if delay { try await Task.sleep(for: .milliseconds(120)) }
        let isPaired = lock.withLock { paired }
        return try decode("{\"name\":\"Test Host\",\"uniqueID\":\"host1\",\"paired\":\(isPaired),\"appVersion\":\"7.1.431.-1\",\"codecSupport\":1,\"currentGame\":0}")
    }
    func pair(pin: String) async throws -> PairedHost {
        lock.withLock { paired = true }
        return try decode("{\"certificate\":\"pinned certificate\",\"uniqueID\":\"host1\"}")
    }
    func apps() async throws -> [HostApp] {
        try decode("[{\"id\":1,\"name\":\"Desktop\",\"uuid\":\"app1\",\"hdrSupported\":true}]")
    }
    func launch(_ options: LaunchOptions) async throws -> LaunchedStream { throw HostConnectionError("not used") }
    func cancel() {}
}
private final class MemoryVault: CredentialsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var certificates: [String:String] = [:]
    let failSave: Bool
    init(failSave: Bool = false) { self.failSave = failSave }
    func identity() throws -> ClientIdentity { try decode("{\"uniqueID\":\"test\",\"certificate\":\"test\",\"privateKey\":\"test\"}") }
    func certificate(for endpoint: String) throws -> String? { lock.withLock { certificates[endpoint] } }
    func saveCertificate(_ certificate: String, for endpoint: String) throws {
        if failSave { throw HostConnectionError("Keychain test failure") }
        lock.withLock { certificates[endpoint] = certificate }
    }
}
private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
