import Foundation
import Observation
import MysticKit
import MysticCore

/// Bitrate and frame rate during a stream: manual live changes and automatic bitrate.
@MainActor @Observable
public final class StreamRatesModel {
    public private(set) var liveAvailable=false
    public private(set) var httpBitrate=false
    public private(set) var busy=false
    public private(set) var message="Start a stream to change its rates."
    public private(set) var appliedKbps: UInt32?
    public private(set) var appliedFPS: UInt32?
    public private(set) var status="Fixed bitrate"
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var automatic=false
    @ObservationIgnored private var initialized=false
    @ObservationIgnored private var lastDecoded: UInt64=0
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }

    public var launchKbps: UInt32 { UInt32(model.plan?.configuration.bitrateKbps ?? 10_000) }
    public var launchFPS: UInt32 { UInt32(model.plan?.configuration.fps ?? 60) }
    /// Automatic bitrate owns the rate, so the health report offers no trial.
    public var automaticActive: Bool { automatic }
    /// The stream's bitrate as far as Mystic knows it: the last applied, else the launch request.
    public var currentKbps: UInt32 { appliedKbps ?? launchKbps }
    /// A health-report trial step was applied.
    func noteTrial(kbps: UInt32,undo: Bool) {
        appliedKbps=kbps
        status=undo ? "Bitrate restored: \(kbps) kbps" : "Trial bitrate: \(kbps) kbps"
    }
    public var canChange: Bool { model.phase == .streaming && !model.isBusy && (liveAvailable || httpBitrate) }

    /// Clears manual rate state; automatic bitrate is stopped separately.
    func resetManual() {
        liveAvailable=false;httpBitrate=false;busy=false
        appliedKbps=nil;appliedFPS=nil;message="Start a stream to change its rates."
    }
    func stopAutomatic(status: String? = nil) {
        task?.cancel();task=nil;automatic=false
        if let status { self.status=status }
    }
    /// Before a launch attempt: telemetry and the automatic-bitrate handshake start over.
    func prepareLaunch() { resetManual();lastDecoded=0;initialized=false }
    func clearDecodedCount() { lastDecoded=0 }
    func streamStarted(launch: LaunchedStream,adaptive: Bool,configuration: StreamConfiguration) {
        httpBitrate=launch.runtimeBitrate == true
        message="Rates affect this stream only. Manual changes pause automatic bitrate until reconnect."
        automatic=adaptive && launch.runtimeBitrate == true
        status = !adaptive ? "Fixed bitrate: \(configuration.bitrateKbps/1000) Mbps" :
            (launch.runtimeBitrate == true ? "Automatic bitrate: waiting for video…" : "Automatic bitrate unavailable on this host; using fixed bitrate.")
    }

    public func refresh() async {
        guard model.phase == .streaming,!busy,let session=model.session else { return }
        let token=model.generation
        do {
            let state=try await session.liveRates(kbps:0,fpsMilliHz:0)
            guard model.generation == token,!busy else { return }
            liveAvailable=state.available
        } catch { /* Unsupported test/legacy engines leave the HTTP fallback available. */ }
    }
    public func change(kbps: UInt32,fpsMilliHz: UInt32,context: UUID) async {
        guard context == model.generation,canChange,let connection=model.connection,let session=model.session else { return }
        guard (kbps == 0 || (1...150_000).contains(kbps)),
            (fpsMilliHz == 0 || (fpsMilliHz >= 10_000 && UInt64(fpsMilliHz) <= min(240_000,UInt64(launchFPS)*1000))),
            kbps != 0 || fpsMilliHz != 0 else { message="Choose valid rates within the stream's launch frame rate.";return }
        guard fpsMilliHz == 0 || liveAvailable else { message="This host supports bitrate changes only.";return }
        let token=model.generation
        busy=true;message="Waiting for host confirmation…"
        // Drain any older automatic write before sending the manual one. A manual change also
        // replaces a health-report trial.
        automatic=false
        await session.trialClear()
        let pending=task
        await pending?.value
        guard model.generation == token else { return }
        defer { if model.generation == token { busy=false } }
        do {
            if liveAvailable {
                var state=try await session.liveRates(kbps:kbps,fpsMilliHz:fpsMilliHz)
                for _ in 0..<30 {
                    guard model.generation == token,model.phase == .streaming else { return }
                    if !state.pending { break }
                    try await Task.sleep(for:.milliseconds(200))
                    guard model.generation == token else { return }
                    state=try await session.liveRates(kbps:0,fpsMilliHz:0)
                }
                guard model.generation == token else { return }
                guard !state.pending else { throw HostConnectionError("The host rate change timed out. Applied rates are unknown.") }
                if let error=state.error { throw HostConnectionError(error) }
                guard let result=state.result else { throw HostConnectionError("The host returned no applied rates.") }
                appliedKbps=result.kbps;appliedFPS=result.fpsMilliHz
                model.decoder?.setLiveFrameRate((result.fpsMilliHz+999)/1000)
                message=result.summary
            } else {
                let applied=try await connection.setBitrate(kbps:kbps)
                guard model.generation == token else { return }
                guard (1...150_000).contains(applied) else { throw HostConnectionError("The host returned an unsupported bitrate.") }
                appliedKbps=applied
                message=applied == kbps ? "Bitrate applied by host." : "Bitrate limited by host."
            }
            status="Manual bitrate: \(appliedKbps ?? 0) kbps"
        } catch {
            guard model.generation == token else { return }
            appliedKbps=nil;appliedFPS=nil
            message=error.localizedDescription
            status="Manual rate change uncertain; automatic bitrate paused."
        }
    }
    /// One automatic-bitrate step per media snapshot, at most one host write in flight.
    func adapt(_ snapshot: VideoTelemetrySnapshot) {
        let token=model.generation
        let decoded=snapshot.decoded > lastDecoded
        lastDecoded=snapshot.decoded
        guard model.phase == .streaming,automatic,task == nil,let session=model.session,let connection=model.connection,let plan=model.plan else { return }
        let decode=decoded ? snapshot.timings[.decode].map { Float($0.p95Micros)/1000 } : nil
        task=Task { [weak self] in
            guard let self else { return }
            defer { if self.model.generation == token { self.task=nil } }
            do {
                // The first tick establishes the actual host rate before making policy decisions.
                if !self.initialized {
                    guard decoded else { return }
                    let ceiling=UInt32(plan.configuration.bitrateKbps)
                    let applied=try await connection.setBitrate(kbps:ceiling)
                    guard self.model.generation == token,!Task.isCancelled else { return }
                    guard applied > 0,applied <= ceiling,await session.beginAdaptiveBitrate(ceiling:ceiling,current:applied) else {
                        throw HostConnectionError("The host could not start automatic bitrate within the selected limit.")
                    }
                    guard self.model.generation == token,!Task.isCancelled else { return }
                    self.initialized=true
                    self.status="Automatic bitrate: \(applied/1000) Mbps"
                    return
                }
                guard let requested=await session.suggestedBitrate(decodeMillis:decode ?? -1) else { return }
                guard self.model.generation == token,!Task.isCancelled else { return }
                let applied=try await connection.setBitrate(kbps:requested)
                guard self.model.generation == token,!Task.isCancelled else { return }
                guard applied > 0,applied <= UInt32(plan.configuration.bitrateKbps) else {
                    throw HostConnectionError("The host returned a bitrate outside the selected limit.")
                }
                await session.appliedBitrate(requested:requested,applied:applied)
                guard self.model.generation == token else { return }
                self.status="Automatic bitrate: \(applied/1000) Mbps"
            } catch {
                guard self.model.generation == token else { return }
                self.automatic=false
                self.status="Automatic bitrate stopped: \(error.localizedDescription)"
            }
        }
    }
}
