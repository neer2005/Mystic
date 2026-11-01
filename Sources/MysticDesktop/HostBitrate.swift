import Foundation
import MysticKit
import MysticCore

/// Automatic bitrate run by a Foundation Sunshine host, for hosts without Rubylight's live
/// bitrate: the stream turns the host's controller on, reports its network every three seconds
/// and shows the bitrate the host chose, as Nightjar's desktop client does (`host_abr.rs`).
/// Requests go over their own connection, so turning the controller off still reaches the host
/// after a disconnect has cancelled the stream's.
@MainActor
final class HostBitrateController {
    private var window: HostBitrateWindow?
    private var host: (any HostService)?
    private var stopping: Task<Void,Never>?
    private var lastDecoded: UInt64?
    /// Changed by every stop, so a late start or answer knows its stream has gone.
    private var epoch=0
    var active: Bool { window != nil }

    /// `done` gets the bitrate the host starts from, nil when it has no controller.
    func start(maxKbps: UInt32,nowMillis: @escaping () -> UInt64,connect: @escaping () async throws -> any HostService,
               done: @escaping (Result<UInt32?,any Error>) -> Void) {
        stop()
        let epoch=epoch,previous=stopping
        Task { [weak self] in
            // An off sent just before must not land after this on.
            await previous?.value
            do {
                let host=try await connect()
                let started=try await host.startHostBitrate(maxKbps:maxKbps)
                guard let self,self.epoch == epoch else {
                    // The stream ended while the host turned it on: nobody else turns it off.
                    if started != nil { try? await host.stopHostBitrate() }
                    host.cancel();return
                }
                guard let started else { host.cancel();done(.success(nil));return }
                let window=HostBitrateWindow(initialKbps:started.initialKbps,streamKbps:maxKbps,nowMillis:nowMillis())
                self.host=host;self.window=window
                done(.success(window.currentKbps))
            } catch {
                guard let self,self.epoch == epoch else { return }
                done(.failure(error))
            }
        }
    }
    /// Turns the host's controller off, without waiting for the host.
    func stop() {
        epoch&+=1;window=nil;lastDecoded=nil
        guard let host else { return }
        self.host=nil
        let previous=stopping
        stopping=Task {
            await previous?.value
            try? await host.stopHostBitrate()
            host.cancel()
        }
    }
    /// One second's figures; every third second they go to the host, and `moved` gets the
    /// bitrate it moved to and why.
    func tick(measures: NetworkMeasures?,decoded: UInt64,nowMillis: UInt64,moved: @escaping (UInt32,String) -> Void) {
        guard var window,let host else { return }
        let fresh=decoded >= (lastDecoded ?? decoded) ? decoded-(lastDecoded ?? decoded) : 0
        lastDecoded=decoded
        window.add(completed:measures?.completedFrames ?? 0,dropped:measures?.droppedFrames ?? 0,decoded:fresh)
        let report=window.due(nowMillis:nowMillis,rttMillis:measures?.rttMs)
        self.window=window
        guard let report else { return }
        let epoch=epoch
        Task { [weak self] in
            let action=try? await host.hostBitrateFeedback(report)
            guard let self,self.epoch == epoch else { return }
            if let kbps=self.window?.answered(newKbps:action?.newKbps) { moved(kbps,action?.reason ?? "") }
        }
    }
}
