import Foundation
import Observation
import MysticKit
import MysticCore

/// Refreshes Home from every saved PC, loads its artwork and wakes sleeping PCs.
/// Persistence and merging belong to `HomeLibrary`; this owns the network side.
@MainActor @Observable
public final class HomeSync {
    public private(set) var busy=false
    public private(set) var message="Cached games remain available when a PC is unreachable."
    @ObservationIgnored private var epoch=UUID()
    @ObservationIgnored private var connections: [String:any HostService]=[:]
    @ObservationIgnored private var artRequests=Set<String>()
    @ObservationIgnored private unowned let model: ConnectionModel
    private struct PairingRequired: Error {}
    init(model: ConnectionModel) { self.model=model }

    private var home: HomeLibrary { model.home }
    private var blocked: Bool { model.isBusy || model.hasSession }

    func cancel() {
        epoch=UUID();busy=false
        for connection in connections.values { connection.cancel() };connections=[:];artRequests=[]
        for (id,state) in home.reach where state == .checking { home.setReach(id,.unknown) }
    }
    public func refresh() async {
        guard model.showingHome,!busy,!blocked else { return }
        cancel();let epoch=epoch
        let savedHosts=model.savedHosts
        home.reconcile(savedHosts.hosts);busy=true;message="Refreshing paired PCs…"
        defer { if self.epoch == epoch { busy=false;message="Home shows live games where reachable and cached games elsewhere." } }
        var seen=Set<String>()
        let hosts=savedHosts.hosts,factory=model.makeHost,vault=model.vault
        for saved in hosts {
            let key=HomePC.key(uniqueID:saved.uniqueID,endpoint:saved.endpoint)
            guard self.epoch == epoch,!Task.isCancelled else { return }
            guard seen.insert(key).inserted else { continue }
            home.setReach(key,.checking)
            do {
                let service=try await Task.detached {
                    guard let certificate=try vault.certificate(for:saved.endpoint.id) else { throw PairingRequired() }
                    return try factory(saved.endpoint.address,saved.endpoint.port,vault.identity(),certificate)
                }.value
                guard self.epoch == epoch else { service.cancel();return }
                connections[key]=service
                let info=try await service.serverInfo()
                guard self.epoch == epoch else { return }
                guard info.paired,(saved.uniqueID == nil || saved.uniqueID == info.uniqueID) else {
                    home.setReach(key,.pairing,notice:"Pairing or host identity changed. Connect to this PC to verify it.");service.cancel();connections[key]=nil;continue
                }
                let classic=try await service.apps()
                var library: HostLibrary?
                var libraryFailed=false
                do { library=try await service.library() } catch { libraryFailed=true }
                let wake=try? await service.wakeTargets()
                guard self.epoch == epoch else { return }
                if !libraryFailed || home.pc(key) == nil {
                    home.record(host:info,endpoint:saved.endpoint,apps:library?.merging(apps:classic) ?? classic,library:library,wake:wake)
                }
                let realKey=HomePC.key(uniqueID:info.uniqueID,endpoint:saved.endpoint)
                if realKey != key { connections[realKey]=service;connections[key]=nil }
                savedHosts.remember(endpoint:saved.endpoint,name:info.name,uniqueID:info.uniqueID)
                home.setReach(realKey,.online,notice:libraryFailed ? "Native library unavailable; showing cached games or host apps." : nil)
            } catch {
                guard self.epoch == epoch else { return }
                connections[key]?.cancel();connections[key]=nil
                if error is PairingRequired { home.setReach(key,.pairing,notice:"Pair with this PC to load its library.") }
                else { home.setReach(key,.offline,notice:error.localizedDescription) }
            }
        }
    }
    public func loadArt(_ copy: HomeInstallation) async {
        if home.cachedArt(copy) != nil { return }
        let key=home.artKey(copy),epoch=epoch
        guard home.reach[copy.hostID] == .online,let service=connections[copy.hostID],artRequests.insert(key).inserted else { return }
        let data=try? await service.artwork(appID:copy.app.id)
        guard self.epoch == epoch,let data else { return }
        home.saveArt(data,for:copy)
    }
    public func wake(_ id: String) async {
        guard !busy,!blocked,let pc=home.pc(id) else { return }
        busy=true;let epoch=epoch
        defer { if self.epoch == epoch { busy=false } }
        do {
            _ = try await pc.wake.send(to:pc.endpoint.address)
            guard self.epoch == epoch else { return }
            message="Wake packets sent to \(pc.name). Wake depends on the PC and network; refresh to check whether it is online."
        } catch { if self.epoch == epoch { message=error.localizedDescription } }
    }
}
