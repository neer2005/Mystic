import Foundation
import Observation
import MysticKit
import MysticCore

/// "Why did my stream stutter?": Nightjar's stream doctor fed once a second, the network
/// figures for the overlay, and the reversible bitrate trial the report can offer.
@MainActor @Observable
public final class StreamHealthModel {
    public private(set) var measures: NetworkMeasures?
    public private(set) var report: StreamHealthReport?
    public private(set) var trialBusy=false
    public private(set) var trialMessage: String?
    @ObservationIgnored private var lastTick: UInt64?
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }

    func reset() { measures=nil;report=nil;trialBusy=false;trialMessage=nil;lastTick=nil }

    /// One doctor tick from the latest telemetry. Decode uses the median, as Nightjar uses the
    /// tick's mean; host and display waits use the p95 the doctor compares.
    func tick(_ snapshot: VideoTelemetrySnapshot) async {
        guard model.phase == .streaming,let session=model.session else { return }
        let token=model.generation,now=DispatchTime.now().uptimeNanoseconds/1_000_000
        func ms(_ micros: Int64?) -> Float { micros.map { Float($0)/1000 } ?? .nan }
        var timings=HealthTimings()
        timings.decodeMs=ms(snapshot.timings[.decode]?.p50Micros)
        timings.hostP95Ms=ms(snapshot.timings[.hostProcessing]?.p95Micros)
        timings.displayP95Ms=ms(snapshot.timings[.displayWait]?.p95Micros)
        timings.releasedFps=snapshot.decodedFPS.map(Float.init) ?? .nan
        timings.shownFps=snapshot.enqueuedFPS.map(Float.init) ?? .nan
        timings.thermalLevel=Self.thermalLevel(ProcessInfo.processInfo.thermalState)
        timings.intervalMs=UInt32(clamping:lastTick.map { now-$0 } ?? 1000)
        lastTick=now
        let measured=await session.healthTick(timings)
        guard model.generation == token else { return }
        measures=measured
    }
    nonisolated static func thermalLevel(_ state: ProcessInfo.ThermalState) -> UInt32 {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        default: 3
        }
    }
    public var canReport: Bool { model.phase == .streaming }
    public func refreshReport() async {
        guard canReport,let session=model.session else { return }
        let token=model.generation
        let value=await session.healthReport(currentKbps:model.rates.currentKbps,runtimeBitrate:model.rates.httpBitrate,
                                             automatic:model.rates.automaticActive,busy:model.isBusy || trialBusy)
        guard model.generation == token else { return }
        report=value
    }
    /// One trial step: 20 % below the encoder's live bitrate, or back to where it was.
    public func runTrial(undo: Bool) async {
        guard let report,report.offer == (undo ? .undo : .tryLower),!trialBusy,
              let session=model.session,let connection=model.connection else { return }
        let token=model.generation
        trialBusy=true;trialMessage=undo ? "Restoring the bitrate…" : "Asking the host for a lower bitrate…"
        defer { if model.generation == token { trialBusy=false } }
        do {
            let live=try await connection.liveBitrate()
            guard model.generation == token else { return }
            guard live.runtime else { trialMessage="This host does not allow bitrate changes during a stream.";return }
            switch await session.trialBegin(undo:undo,liveKbps:live.kbps) {
            case .failure(let refusal):
                trialMessage=switch refusal {
                case .unavailable: "The host did not report its current encoder bitrate. The trial was not applied."
                case .minimum: "The encoder is already at the minimum trial bitrate. No change was made."
                case .replaced: "The host bitrate has changed since the trial. Undo was canceled to preserve that change."
                }
            case .success(let target):
                let applied=try await connection.setBitrate(kbps:target)
                guard model.generation == token else { return }
                await session.trialApplied(undo:undo,previousKbps:live.kbps,appliedKbps:applied)
                model.rates.noteTrial(kbps:applied,undo:undo)
                trialMessage="Host applied \(String(format:"%.1f",Double(applied)/1000)) Mbps."
            }
        } catch {
            guard model.generation == token else { return }
            trialMessage=error.localizedDescription
        }
        guard model.generation == token else { return }
        trialBusy=false
        await refreshReport()
    }
}
