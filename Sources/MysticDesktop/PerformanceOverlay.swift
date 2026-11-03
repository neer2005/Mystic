import AppKit
import Foundation
import Observation
import SwiftUI
import MysticCore
import MysticKit

/// One second's measurements for the performance overlay; nil where nothing was measured.
struct OverlayMeasures: Equatable {
    /// Pictures the renderer accepted per second: the rate this Mac shows.
    var renderedFps: Double?
    var receivedFps: Double?
    var videoMbps: Double?
    var lossPercent: Double?
    var networkMs: Double?
    var varianceMs: Double?
    var hostMs: Double?
    var decodeMs: Double?
    var renderMs: Double?

    init(renderedFps: Double? = nil,receivedFps: Double? = nil,videoMbps: Double? = nil,lossPercent: Double? = nil,
         networkMs: Double? = nil,varianceMs: Double? = nil,hostMs: Double? = nil,decodeMs: Double? = nil,renderMs: Double? = nil) {
        self.renderedFps=renderedFps;self.receivedFps=receivedFps;self.videoMbps=videoMbps;self.lossPercent=lossPercent
        self.networkMs=networkMs;self.varianceMs=varianceMs;self.hostMs=hostMs;self.decodeMs=decodeMs;self.renderMs=renderMs
    }
    init(snapshot: VideoTelemetrySnapshot?,network: NetworkMeasures?) {
        func ms(_ stage: VideoTimingStage) -> Double? { snapshot?.timings[stage].map { Double($0.p50Micros)/1000 } }
        self.init(renderedFps:snapshot?.enqueuedFPS,receivedFps:network?.receivedFps,videoMbps:network?.videoMbps,
                  lossPercent:network?.lossPercent,networkMs:network?.rttMs,varianceMs:network?.rttVarianceMs,
                  hostMs:ms(.hostProcessing),decodeMs:ms(.decode),renderMs:ms(.rendererEnqueue))
    }
}

/// The overlay's text in its three modes, as Nightjar's desktop `stream/overlay.rs` (after
/// Android's `PerformanceOverlay`). Labels stay English, as Nightjar's do.
enum OverlayText {
    /// "119.9 FPS · 8 ms RTT · 0.1% loss", each once measured, behind the health mark.
    static func compact(_ m: OverlayMeasures) -> (health: OverlayHealth,text: String) {
        var values: [String]=[]
        if let fps=m.renderedFps { values.append(String(format:"%.1f FPS",fps)) }
        if let ms=m.networkMs { values.append(String(format:"%.0f ms RTT",ms)) }
        if let loss=m.lossPercent { values.append(String(format:"%.1f%% loss",loss)) }
        return (OverlayHealth.of(shownFps:m.renderedFps,receivedFps:m.receivedFps,refreshHz:NSScreen.main.map(DisplayRefresh.hertz),networkMs:m.networkMs,lossPercent:m.lossPercent,decodeMs:m.decodeMs),
                values.joined(separator:" · "))
    }
    static func value(_ value: Double?,_ decimals: Int) -> String {
        guard let value,value.isFinite,value >= 0 else { return "—" }
        return String(format:"%.\(decimals)f",value)
    }
    /// Android's six lines: the stream, frame rates, video payload and loss, network, host, this Mac.
    static func statistics(stream: String,_ m: OverlayMeasures) -> [(String,String)] {
        [("Stream",stream),
         ("Frames","\(value(m.renderedFps,1)) rendered · \(value(m.receivedFps,1)) received FPS"),
         ("Video","\(value(m.videoMbps,1)) Mbps payload · \(value(m.lossPercent,2))% loss"),
         ("Network","\(value(m.networkMs,0)) ms RTT (±\(value(m.varianceMs,0)) ms)"),
         ("Host processing","\(value(m.hostMs,1)) ms"),
         ("Client","\(value(m.decodeMs,2)) ms decode · \(value(m.renderMs,2)) ms render")]
    }
    /// The host's readings: CPU and each GPU's usage, temperature and power in Statistics; the
    /// sample time and each GPU in full in Debug.
    static func hardware(_ h: HostHardware,debug: Bool) -> [(String,String)] {
        func reading(_ values: [String:Double]?,_ key: String,_ decimals: Int) -> String { value(values?[key],decimals) }
        var lines=[("Host CPU","\(reading(h.cpu,"cpu_usage_percent",1))%")]
        if debug { lines.append(("Host sample","\(h.sampledAtUnixMs ?? 0) ms since Unix epoch · Interval: \(h.intervalMs ?? 0) ms")) }
        for gpu in h.gpus ?? [] {
            let r=gpu.metrics
            guard debug else {
                lines.append(("Host GPU \(gpu.id)","\(reading(r,"gpu_usage_percent",1))% · \(reading(r,"gpu_temperature_c",1)) °C · \(reading(r,"gpu_power_w",1)) W"))
                continue
            }
            lines.append(("GPU \(gpu.id)",gpu.name.isEmpty ? "Unnamed GPU" : gpu.name))
            lines.append(("Usage","\(reading(r,"gpu_usage_percent",1))% · GPU clock: \(reading(r,"gpu_clock_mhz",0)) MHz · Memory clock: \(reading(r,"gpu_memory_clock_mhz",0)) MHz"))
            lines.append(("Temperatures","GPU: \(reading(r,"gpu_temperature_c",1)) °C · Hotspot: \(reading(r,"gpu_hotspot_temperature_c",1)) °C · Memory: \(reading(r,"gpu_memory_temperature_c",1)) °C"))
            lines.append(("Voltage","\(reading(r,"gpu_voltage_mv",0)) mV · Fan: \(reading(r,"gpu_fan_rpm",0)) RPM (\(reading(r,"gpu_fan_percent",1))%)"))
            lines.append(("Power","GPU: \(reading(r,"gpu_power_w",1)) W · Board: \(reading(r,"gpu_board_power_w",1)) W"))
            lines.append(("VRAM","\(reading(r,"gpu_vram_used_mb",0)) MB (\(reading(r,"gpu_vram_usage_percent",1))%)"))
        }
        return lines
    }
}

/// The host's hardware readings while the overlay shows them (Statistics or Debug), on
/// Nightjar's shared poll: at once, then at the host's interval (at least 2 s), 10 s after a
/// failure, never again once the host says it has none.
@MainActor @Observable
public final class HostHardwareModel {
    public private(set) var reading: HostHardware?
    @ObservationIgnored private var poll=HardwarePoll()
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }
    func reset() { poll=HardwarePoll();reading=nil }
    func tick(nowMillis: UInt64) {
        let wanted=model.phase == .streaming && model.showLatencyHUD && model.overlayMode != .compact
        if !poll.fresh(nowMillis:nowMillis) { reading=nil }
        guard let generation=poll.due(nowMillis:nowMillis,wanted:wanted),let connection=model.connection else { return }
        let token=model.generation
        Task { [weak self] in
            let answer: HardwarePoll.Answer,value: HostHardware?
            do {
                let hardware=try await connection.hardwareMetrics()
                if hardware.available,let at=hardware.sampledAtUnixMs { answer = .sample(sampledAtUnixMs:at,intervalMs:hardware.intervalMs ?? 0);value=hardware }
                else { answer = .unavailable;value=nil }
            } catch { answer = .failed;value=nil }
            guard let self,self.model.generation == token else { return }
            if self.poll.answered(generation:generation,nowMillis:self.model.nowMillis(),answer) { self.reading=value }
        }
    }
}

/// The overlay over the video in the chosen mode; Debug keeps the latency HUD's details.
struct PerformanceOverlay<Details: View>: View {
    let mode: OverlayMode
    let stream: String
    let measures: OverlayMeasures
    let hardware: HostHardware?
    @ViewBuilder let details: () -> Details
    private func color(_ health: OverlayHealth) -> Color {
        switch health {
        case .good: Color(red:0x69/255,green:0xdb/255,blue:0x7c/255)
        case .fair: Color(red:1,green:0xc8/255,blue:0x57/255)
        case .poor: Color(red:1,green:0x6b/255,blue:0x6b/255)
        case .unknown: Color(red:0x9a/255,green:0xa0/255,blue:0xae/255)
        }
    }
    var body: some View {
        Group {
            if mode == .compact {
                let line=OverlayText.compact(measures)
                HStack(spacing:6) {
                    Text(line.health.glyph).foregroundStyle(color(line.health)).accessibilityLabel("Stream health \(String(describing:line.health))")
                    Text(line.text.isEmpty ? "Waiting for measurements…" : line.text)
                }
            } else {
                VStack(alignment:.leading,spacing:6) {
                    Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:3) {
                        ForEach(Array((OverlayText.statistics(stream:stream,measures)+(hardware.map { OverlayText.hardware($0,debug:mode == .debug) } ?? [])).enumerated()),id:\.offset) { _,line in
                            GridRow { Text(line.0).foregroundStyle(.secondary);Text(line.1) }
                        }
                    }
                    if mode == .debug { Divider().overlay(.white.opacity(0.3));details() }
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(mode == .compact ? 8 : 12)
        .background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.combine)
    }
}
