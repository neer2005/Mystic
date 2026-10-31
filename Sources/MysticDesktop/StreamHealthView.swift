import SwiftUI
import AppKit
import MysticKit

/// The report's wording, from Nightjar's desktop doctor, for this Mac.
enum StreamHealthText {
    static func body(_ report: StreamHealthReport) -> [String] {
        var parts=["Active samples: \(report.samples). Evidence covers the last 30 seconds. Several stages can be slow at once; these observations suggest causes, not a guaranteed diagnosis. No video or personal information is recorded."]
        if !report.recent || report.samples < 3 {
            parts.append("Not enough recent video to assess. Play for a few seconds with this window closed, then return just after a stutter.")
        } else if report.findings.isEmpty {
            parts.append("No repeated bottleneck was observed in the available measurements. Short spikes and unmeasured stages can still cause a stutter.")
        }
        parts+=report.findings.map { finding(_:$0,report) }
        return parts
    }
    static func finding(_ finding: StreamHealthReport.Finding,_ report: StreamHealthReport) -> String {
        switch finding {
        case .network: "Network: repeated frame loss or round-trip variation. Try a lower bitrate, a wired connection or a less congested Wi-Fi network."
        case .decoder: "Decode: output repeatedly took at least one frame interval. Try a lower resolution or frame rate; lowering bitrate alone may not help."
        case .host: "Host: the slower processing samples exceeded the frame interval. Compare game and GPU load and a lower game frame limit. This measurement includes more than encoding."
        case .presentation: "Presentation: frames were released faster than they were shown, with long display waits. Compare frame-pacing modes and the display's refresh rate."
        case .heat: "Temperature: this Mac reported thermal pressure. Lower the frame rate or resolution, and let it cool."
        case .bursts: "Bursts: in \(report.lateSamples) of the last \(report.samples) seconds, the network held frames back and delivered several at once, although the host sent them on time. A cable or a less busy 5 or 6 GHz Wi-Fi channel helps."
        case .periodic: "Repeating stalls: \(report.stalls) network stalls in the last 20 minutes started about every \(period(report.stallPeriodMs)). A steady rhythm like this usually comes from background Wi-Fi scans on this Mac or on the host. Connect either by cable, or stop tools that scan for Wi-Fi networks or nearby devices while streaming."
        }
    }
    /// Seconds below 90 s, otherwise minutes to the half minute, as Nightjar words a rhythm.
    static func period(_ milliseconds: UInt64) -> String {
        let seconds=(milliseconds+500)/1000
        if seconds < 90 { return "\(seconds) s" }
        let minutes=(Double(seconds)/30).rounded()/2
        return minutes.truncatingRemainder(dividingBy:1) == 0 ? "\(Int(minutes)) min" : String(format:"%.1f min",minutes)
    }
    static func value(_ value: Double) -> String { value.isFinite && value >= 0 ? String(format:"%.1f",value) : "no data yet" }
    static func evidence(_ report: StreamHealthReport) -> [(String,String)] {
        [("Frame loss",value(report.worstLossPercent)+(report.worstLossPercent >= 0 ? " %" : "")),
         ("Decode",value(report.worstDecodeMs)+(report.worstDecodeMs >= 0 ? " ms" : "")),
         (report.hostIncludesSend ? "Host to network p95" : "Host processing p95",value(report.worstHostP95Ms)+(report.worstHostP95Ms >= 0 ? " ms" : "")),
         ("Display wait p95",value(report.worstDisplayP95Ms)+(report.worstDisplayP95Ms >= 0 ? " ms" : ""))]
    }
    static let trialHelp="A bitrate trial changes only this session. Compare another 30 seconds of similar gameplay, then return here to undo it. Manual or automatic bitrate changes replace the trial."
    /// What Copy Report puts on the clipboard: only the displayed evidence and advice.
    static func copy(_ report: StreamHealthReport) -> String {
        let values=evidence(report).map { label,value in label+": "+value }.joined(separator:"\n")
        let largest="Largest observed values:\n"+values+"\nThese stages do not add up to input-to-screen latency."
        return (body(report)+[largest]).joined(separator:"\n\n")
    }
}

struct StreamHealthView: View {
    @Bindable var model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    private var health: StreamHealthModel { model.health }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Why Did My Stream Stutter?").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if let report=health.report {
                        ForEach(Array(StreamHealthText.body(report).enumerated()),id:\.offset) { _,text in
                            Text(text).fixedSize(horizontal:false,vertical:true)
                        }
                        GroupBox("Largest Observed Values") {
                            Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:4) {
                                ForEach(StreamHealthText.evidence(report),id:\.0) { label,value in
                                    GridRow { Text(label).foregroundStyle(.secondary);Text(value).monospacedDigit() }
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            Text("These stages do not add up to input-to-screen latency.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let measures=health.measures { GroupBox("Network Now") { NetworkFigures(measures:measures) } }
                        if report.offer != .none {
                            Text(StreamHealthText.trialHelp).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView("Reading the stream's measurements…")
                    }
                    if let message=health.trialMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:460)
            HStack {
                Button("Copy Report",systemImage:"doc.on.doc") {
                    guard let report=health.report else { return }
                    NSPasteboard.general.clearContents();NSPasteboard.general.setString(StreamHealthText.copy(report),forType:.string)
                }.disabled(health.report == nil)
                Spacer()
                if let offer=health.report?.offer,offer != .none {
                    Button(offer == .undo ? "Undo Bitrate Trial" : "Try a Lower Bitrate") { Task { await health.runTrial(undo:offer == .undo) } }
                        .disabled(health.trialBusy)
                }
                Button("Refresh",systemImage:"arrow.clockwise") { Task { await health.refreshReport() } }
                    .disabled(!health.canReport || health.trialBusy)
            }
        }
        .padding(24).frame(width:520)
        .task { await health.refreshReport() }
    }
}

/// The engine's network figures, in the report and the latency overlay.
struct NetworkFigures: View {
    let measures: NetworkMeasures
    private func ms(_ value: Double?) -> String { value.map { String(format:"%.1f ms",$0) } ?? "—" }
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("Round trip \(ms(measures.rttMs))\(measures.rttVarianceMs.map { String(format:" ± %.1f",$0) } ?? "") · Jitter \(ms(measures.jitterMs))")
            Text("Frame loss \(measures.lossPercent.map { String(format:"%.1f %%",$0) } ?? "—") · Received \(measures.receivedFps.map { String(format:"%.1f fps",$0) } ?? "—")")
            if measures.poorConnection { Text("The host reports a poor connection.") }
            if measures.inputHeld { Text("The network is silent; input is held until the host answers.") }
        }.monospacedDigit()
    }
}
