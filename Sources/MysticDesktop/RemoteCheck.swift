import Foundation
import Observation
import SwiftUI
import MysticKit

/// What a remote access check found, in the words of Nightjar's host page (`host_page.rs`,
/// after Android's RemoteSetupActivity).
struct RemoteCheckReport: Equatable {
    var summary: String
    /// What the route means for streaming, and its name; only for a verified PC.
    var route: String? = nil
    var path: String? = nil
    var latencyMs: Double? = nil,jitterMs: Double? = nil,lossPercent: Double? = nil
    var error: String? = nil
    var verified=false

    static let failed="The paired PC could not be verified. Check that it is awake, the host and VPN are running, and the saved address and streaming ports are correct. If pairing changed, pair again at home. This test cannot distinguish a sleeping PC from a blocked route."
    init(summary: String,error: String? = nil) { self.summary=summary;self.error=error }
    init(_ result: RemoteCheckResult) {
        switch result.outcome {
        case .notPaired:
            self.init(summary:"Pair this PC locally first. Its saved certificate and HTTPS port are required to verify that the remote address reaches your PC.",error:result.error)
        case .wrongHost,.unreachable,.cancelled: self.init(summary:Self.failed,error:result.error)
        case .pairRevoked: self.init(summary:"The PC responded, but this Mac is no longer paired. Pair again at home before testing remote play.")
        case .permissionDenied:
            self.init(summary:"The paired PC responded, but this Mac cannot view streams. Enable viewing or launching applications for this device in your host's settings or web UI.")
        case .verified:
            self.init(summary:"The paired PC responded on this network. Next, try a normal stream at a modest bitrate; HTTPS reachability does not verify video/audio UDP ports or sustained streaming performance.",error:result.error)
            verified=true
            latencyMs=result.stats?.latencyMs;jitterMs=result.stats?.jitterMs;lossPercent=result.stats?.lossPercent
            switch result.path ?? .unknown {
            case .direct: route="Tailscale reports a direct path for this connection. Direct paths usually provide the best throughput and latency.";path="Direct"
            case .relay: route="Tailscale reports a DERP relay. It provides connectivity, but streaming speed may be limited. Check Tailscale's connectivity guidance or configure a suitable peer relay.";path="Relay (DERP)"
            case .peerRelay: route="Tailscale reports a peer relay. Performance depends on that relay and both network paths; compare a real stream.";path="Peer relay"
            case .unknown,.none: route="Direct or relayed path: unavailable. This host, VPN or connection does not expose a current route classification. Check your VPN's status; low ping alone does not prove a direct path.";path="Unavailable"
            }
        }
    }
}

/// Android's remote access check for the connected PC: five pinned HTTPS probes 150 ms apart,
/// then the route the host sees, over its own connection so canceling ends only the check.
@MainActor @Observable
public final class RemoteCheckModel {
    public private(set) var running=false
    private(set) var report: RemoteCheckReport?
    @ObservationIgnored private var host: (any HostService)?
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }
    public var available: Bool { model.host?.paired == true && !model.isBusy }
    public func run() {
        guard available,!running,let id=model.host?.uniqueID else { return }
        running=true;report=nil
        let token=model.generation
        Task { [weak self] in
            guard let self else { return }
            let report: RemoteCheckReport
            do {
                let host=try await self.model.detachedHost()
                self.host=host
                report=RemoteCheckReport(try await host.remoteCheck(uniqueID:id))
            } catch { report=RemoteCheckReport(summary:RemoteCheckReport.failed,error:error.localizedDescription) }
            self.host?.cancel();self.host=nil
            guard self.model.generation == token,self.running else { return }
            self.running=false;self.report=report
            self.model.recordStream("Remote access check: \(report.verified ? "verified" : "not verified")\(report.latencyMs.map { String(format:", %.0f ms",$0) } ?? "").")
        }
    }
    public func cancel() { host?.cancel();host=nil;running=false }
    func reset() { cancel();report=nil }
}

struct RemoteCheckView: View {
    @Bindable var check: RemoteCheckModel
    @Environment(\.dismiss) private var dismiss
    private func ms(_ value: Double?) -> String { value.map { String(format:"%.0f ms",$0) } ?? "—" }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Check Remote Access").font(.headline)
            Text("Tests whether this address reaches your paired PC, as you would from away from home: five secure requests, then the route the host reports.")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if check.running { ProgressView("Checking… this can take up to 20 seconds.") }
            if let report=check.report {
                Label(report.verified ? "Verified" : "Not verified",systemImage:report.verified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.verified ? .green : .orange)
                Text(report.summary).fixedSize(horizontal:false,vertical:true)
                if report.verified {
                    Text("Round trip \(ms(report.latencyMs)) · Jitter \(ms(report.jitterMs)) · Loss \(report.lossPercent.map { String(format:"%.0f%%",$0) } ?? "—")").monospacedDigit()
                    if let path=report.path,let route=report.route { Text("Route: \(path). \(route)").fixedSize(horizontal:false,vertical:true) }
                }
                if let error=report.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            HStack {
                Spacer()
                Button(check.running ? "Cancel" : "Close") { check.cancel();dismiss() }
                Button("Check Again") { check.run() }.disabled(check.running || !check.available).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width:440)
        .onAppear { if check.report == nil { check.run() } }
    }
}
