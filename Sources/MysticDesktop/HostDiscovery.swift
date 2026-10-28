import Foundation
import Observation
import MysticCore

@MainActor
public protocol HostDiscoveryTransport: AnyObject {
    func start(update: @escaping @MainActor ([DiscoveredHost]) -> Void,status: @escaping @MainActor (String) -> Void)
    func stop()
}

@MainActor @Observable
public final class HostDiscovery {
    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var status="LAN discovery stopped"
    public private(set) var isRunning=false
    @ObservationIgnored private let transport: any HostDiscoveryTransport
    @ObservationIgnored private var generation=UUID()
    public init(transport: any HostDiscoveryTransport = BonjourHostDiscovery()) { self.transport=transport }
    public func start() {
        guard !isRunning else { return }
        generation=UUID();let token=generation
        isRunning=true;status="Looking for hosts on your LAN…"
        transport.start(update: { [weak self] hosts in
            guard let self,self.generation == token,self.isRunning else { return }
            var unique:[String:DiscoveredHost]=[:]
            for host in hosts.prefix(64) { unique[host.id]=host }
            self.hosts=unique.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        },status: { [weak self] status in
            guard let self,self.generation == token,self.isRunning else { return };self.status=status
        })
    }
    public func stop() {
        generation=UUID();isRunning=false;transport.stop();hosts=[];status="LAN discovery stopped"
    }
    public func refresh() { stop();start() }
    isolated deinit { transport.stop() }
}

/// NetService delegates are delivered on the main run loop where browsing starts.
/// Discovery supplies an address only: it never reads Keychain or probes host HTTP.
@MainActor
public final class BonjourHostDiscovery: NSObject, HostDiscoveryTransport {
    private var browser: NetServiceBrowser?
    private var services: [String:NetService] = [:]
    private var resolved: [String:DiscoveredHost] = [:]
    private var update: (@MainActor ([DiscoveredHost]) -> Void)?
    private var status: (@MainActor (String) -> Void)?
    public override init() { super.init() }
    public func start(update: @escaping @MainActor ([DiscoveredHost]) -> Void,status: @escaping @MainActor (String) -> Void) {
        stop();self.update=update;self.status=status
        let browser=NetServiceBrowser();self.browser=browser
        browser.delegate=self;browser.searchForServices(ofType:"_nvstream._tcp.",inDomain:"local.")
    }
    public func stop() {
        browser?.delegate=nil;browser?.stop();browser=nil
        for service in services.values { service.delegate=nil;service.stop() }
        services.removeAll();resolved.removeAll();update=nil;status=nil
    }
    private func key(_ service: NetService) -> String { "\(service.domain)|\(service.type)|\(service.name)" }
    private func publish() { update?(Array(resolved.values));status?("Browsing your LAN • \(resolved.count) service\(resolved.count == 1 ? "" : "s") found") }
}

extension BonjourHostDiscovery: @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser,didFind service: NetService,moreComing: Bool) {
        guard self.browser === browser,services.count < 64 else { return }
        let key=key(service)
        guard services[key] == nil else { return }
        services[key]=service;service.delegate=self;service.resolve(withTimeout:5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser,didRemove service: NetService,moreComing: Bool) {
        guard self.browser === browser else { return }
        let key=key(service)
        if let old=services.removeValue(forKey:key) { old.delegate=nil;old.stop() }
        resolved.removeValue(forKey:key);publish()
    }
    public func netServiceDidResolveAddress(_ service: NetService) {
        let key=key(service)
        // A stable .local hostname survives DHCP address changes and retains its endpoint pin.
        guard services[key] === service,
              let host=DiscoveredHost(serviceName:service.name,hostName:service.hostName,port:service.port) else { return }
        resolved[key]=host;publish()
    }
    public func netService(_ service: NetService,didNotResolve errorDict: [String:NSNumber]) {
        guard services[key(service)] === service else { return }
        resolved.removeValue(forKey:key(service));publish()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser,didNotSearch errorDict: [String:NSNumber]) {
        guard self.browser === browser else { return }
        let code=errorDict[NetService.errorCode]?.intValue ?? 0
        status?("LAN discovery unavailable (\(code)). Check Local Network access in System Settings, or enter an address manually.")
    }
}
