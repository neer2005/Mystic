import Foundation
import MysticCore
import Observation
import ServiceManagement

/// Installing the helper and talking to it, behind a seam for tests.
@MainActor
protocol AWDLHelperService: AnyObject {
    var status: AWDLControl.Status { get }
    func register() throws
    func unregister() async throws
    func openApproval()
    func setHeld(_ held: Bool)
}

/// Holds AWDL down during a stream over Wi-Fi, through the privileged helper.
@MainActor @Observable
public final class AWDLControl {
    public enum Status: Equatable,Sendable { case off,needsApproval,ready,unavailable(String) }
    public private(set) var status: Status = .off
    public private(set) var held=false
    @ObservationIgnored var log: (String) -> Void={ _ in }
    @ObservationIgnored private let service: any AWDLHelperService
    @ObservationIgnored private var enabled=false
    @ObservationIgnored private var streaming=false
    @ObservationIgnored private var routeWireless: Bool?
    init(service: any AWDLHelperService) { self.service=service }
    public convenience init() { self.init(service:SystemAWDLHelper()) }

    /// Turning it on installs the helper, which macOS asks the user to approve once.
    public func setEnabled(_ enabled: Bool) {
        self.enabled=enabled
        if enabled {
            do { try service.register() }
            catch { log("AWDL helper could not be installed: \(error.localizedDescription)") }
            refresh()
        } else {
            apply()
            status = .off
            Task { [service,log] in
                do { try await service.unregister() } catch { log("AWDL helper could not be removed: \(error.localizedDescription)") }
            }
        }
    }
    /// macOS keeps its approval in System Settings; look again when coming back from there.
    public func refresh() {
        guard enabled else { status = .off;return }
        status=service.status
        apply()
    }
    public func openApproval() { service.openApproval() }
    func update(streaming: Bool) { self.streaming=streaming;refresh() }
    func update(routeWireless: Bool?) { self.routeWireless=routeWireless;refresh() }
    private func apply() {
        let wanted=status == .ready && AWDLHold.shouldHold(enabled:enabled,streaming:streaming,routeWireless:routeWireless)
        guard wanted != held else { return }
        held=wanted
        service.setHeld(wanted)
        log(wanted ? "Holding AWDL down for this stream." : "Letting AWDL back up.")
    }
}

@MainActor
private final class SystemAWDLHelper: AWDLHelperService {
    private let service=SMAppService.daemon(plistName:AWDLHold.helperPlist)
    private var connection: NSXPCConnection?
    var status: AWDLControl.Status {
        switch service.status {
        case .enabled: .ready
        case .requiresApproval: .needsApproval
        case .notRegistered: .unavailable("The helper is not installed.")
        case .notFound: .unavailable("This copy of Mystic does not contain the helper.")
        @unknown default: .unavailable("macOS reports an unknown helper state.")
        }
    }
    func register() throws { if service.status != .enabled { try service.register() } }
    func unregister() async throws { if service.status != .notRegistered { try await service.unregister() } }
    func openApproval() { SMAppService.openSystemSettingsLoginItems() }
    func setHeld(_ held: Bool) {
        guard held else { connection?.invalidate();connection=nil;return }
        // Connected only while holding: the helper exits, and lets AWDL up, when this goes away.
        let connection=NSXPCConnection(machServiceName:AWDLHold.helperLabel,options:.privileged)
        connection.remoteObjectInterface=NSXPCInterface(with:AWDLHelperProtocol.self)
        connection.resume()
        (connection.remoteObjectProxy as? any AWDLHelperProtocol)?.setHeld(true)
        self.connection=connection
    }
}
