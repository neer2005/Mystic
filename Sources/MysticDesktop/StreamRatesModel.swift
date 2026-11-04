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
    /// Nightjar's loss-based bitrate steers this stream, in place of automatic bitrate.
    @ObservationIgnored private(set) var lossBitrate=false
    /// The bitrate this stream started at: the launch's, or lower after a link test.
    @ObservationIgnored private var streamKbps: UInt32?
    /// A Foundation Sunshine host's own controller, for hosts without live bitrate.
    @ObservationIgnored let hostBitrate=HostBitrateController()
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }

    public var launchKbps: UInt32 { streamKbps ?? UInt32(model.plan?.configuration.bitrateKbps ?? 10_000) }
    public var launchFPS: UInt32 { UInt32(model.plan?.configuration.fps ?? 60) }
    /// Automatic bitrate owns the rate, so the health report offers no trial.
    public var automaticActive: Bool { automatic || hostBitrate.active || lossBitrate }
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
        task?.cancel();task=nil;automatic=false;lossBitrate=false
        hostBitrate.stop()
        if let status { self.status=status }
    }
    /// Before a launch attempt: telemetry and the automatic-bitrate handshake start over.
    func prepareLaunch() { resetManual();lastDecoded=0;initialized=false;lossBitrate=false;streamKbps=nil }
    func clearDecodedCount() { lastDecoded=0 }
    /// `lossBased` is Nightjar's "Lower bitrate when frames are lost": on a stream that takes live
    /// rate changes it steers the bitrate in place of automatic bitrate, as in Nightjar; elsewhere
    /// automatic bitrate runs as set.
    func streamStarted(launch: LaunchedStream,adaptive: Bool,lossBased: Bool = false,configuration: StreamConfiguration) {
        httpBitrate=launch.runtimeBitrate == true
        streamKbps=UInt32(configuration.bitrateKbps)
        message="Rates affect this stream only. Manual changes pause automatic bitrate until reconnect."
        guard lossBased,let session=model.session else {
            startAutomatic(launch:launch,adaptive:adaptive,configuration:configuration);return
        }
        automatic=false
        status="Loss-based bitrate: starting…"
        let token=model.generation
        Task { [weak self] in
            let started=await session.beginLossBitrate(kbps:UInt32(configuration.bitrateKbps))
            guard let self,self.model.generation == token else { return }
            if started {
                self.lossBitrate=true
                self.status="Loss-based bitrate: \(configuration.bitrateKbps/1000) Mbps"
                self.model.recordStream("Loss-based bitrate steers this stream; automatic bitrate stays off.")
            } else {
                self.model.recordStream("Loss-based bitrate needs a PC that changes rates mid-stream; this one does not.")
                self.startAutomatic(launch:launch,adaptive:adaptive,configuration:configuration)
            }
        }
    }
    /// One loss-based tick's outcome, from the stream doctor's tick.
    func lossTick(_ state: LossBitrateState?) {
        guard lossBitrate,let state else { return }
        appliedKbps=state.kbps
        if state.active { status="Loss-based bitrate: \(state.kbps/1000) Mbps";return }
        lossBitrate=false
        status=state.stopped ?? "Loss-based bitrate stopped."
        model.recordStream(status)
    }
    private func startAutomatic(launch: LaunchedStream,adaptive: Bool,configuration: StreamConfiguration) {
        automatic=adaptive && launch.runtimeBitrate == true
        status = !adaptive ? "Fixed bitrate: \(configuration.bitrateKbps/1000) Mbps" :
            (launch.runtimeBitrate == true ? "Automatic bitrate: waiting for video…" : "Automatic bitrate: asking the host…")
        guard adaptive,launch.runtimeBitrate != true else { return }
        // Without live bitrate, a Foundation Sunshine host may run the controller itself.
        let token=model.generation
        hostBitrate.start(maxKbps:UInt32(configuration.bitrateKbps),nowMillis:Self.nowMillis,
                          connect:{ [weak self] in
                              guard let self else { throw HostConnectionError("The stream ended.") }
                              return try await self.model.detachedHost()
                          }) { [weak self] result in
            guard let self,self.model.generation == token else { return }
            switch result {
            case .success(let kbps?): self.appliedKbps=kbps;self.status="Automatic bitrate (host): \(kbps/1000) Mbps"
            case .success(nil): self.status="Automatic bitrate unavailable on this host; using fixed bitrate."
            case .failure(let error): self.status="Automatic bitrate unavailable: \(error.localizedDescription)"
            }
        }
    }
    /// The host's controller takes this second's network figures; every third second it may move the bitrate.
    func hostBitrateTick(_ snapshot: VideoTelemetrySnapshot,measures: NetworkMeasures?) {
        guard model.phase == .streaming,hostBitrate.active else { return }
        let token=model.generation
        hostBitrate.tick(measures:measures,decoded:snapshot.decoded,nowMillis:Self.nowMillis()) { [weak self] kbps,_ in
            guard let self,self.model.generation == token else { return }
            self.appliedKbps=kbps;self.status="Automatic bitrate (host): \(kbps/1000) Mbps"
        }
    }
    private static func nowMillis() -> UInt64 { DispatchTime.now().uptimeNanoseconds/1_000_000 }

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
        automatic=false;hostBitrate.stop()
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
                if fpsMilliHz != 0 { model.quality.manualFrameRateChanged() }
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
        guard model.phase == .streaming,automatic,task == nil,let session=model.session,let connection=model.connection,model.plan != nil else { return }
        let decode=decoded ? snapshot.timings[.decode].map { Float($0.p95Micros)/1000 } : nil
        task=Task { [weak self] in
            guard let self else { return }
            defer { if self.model.generation == token { self.task=nil } }
            do {
                // The first tick establishes the actual host rate before making policy decisions.
                if !self.initialized {
                    guard decoded else { return }
                    // As Nightjar, the ceiling is the bitrate the stream started at.
                    let ceiling=self.launchKbps
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
                guard applied > 0,applied <= self.launchKbps else {
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
