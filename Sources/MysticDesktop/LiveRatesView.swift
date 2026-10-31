import SwiftUI

struct LiveRatesView: View {
    @Bindable var model: ConnectionModel
    @State private var bitrate=""
    @State private var fps=""
    private var kbps: UInt32? {
        guard let n=Double(bitrate),n.isFinite,n >= 1,n <= 150 else { return nil }
        return UInt32((n*1000).rounded())
    }
    private var milliHz: UInt32? {
        guard let n=Double(fps),n.isFinite,n >= 10,n <= Double(model.launchRateFPS),n <= 240 else { return nil }
        return UInt32((n*1000).rounded())
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Live Stream Rates").font(.headline)
            if model.phase != .streaming { Text("Start a stream to change bitrate and frame rate.").foregroundStyle(.secondary) }
            else {
                if let applied=model.appliedLiveKbps { LabeledContent("Host-confirmed bitrate",value:"\(applied) kbps") }
                if let applied=model.appliedLiveFPS { LabeledContent("Host-confirmed frame rate",value:String(format:"%.3f fps",Double(applied)/1000)) }
                if model.appliedLiveKbps == nil { Text("Launch request: \(model.launchRateKbps) kbps · \(model.launchRateFPS) fps").font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Bitrate (Mbps)") { TextField("Bitrate (Mbps)",text:$bitrate).textFieldStyle(.roundedBorder).frame(width:130).disabled(model.liveRateBusy) }
                Text("1–150 Mbps").font(.caption).foregroundStyle(.secondary)
                if model.liveRateAvailable {
                    LabeledContent("Frame rate (fps)") { TextField("Frame rate (fps)",text:$fps).textFieldStyle(.roundedBorder).frame(width:130).disabled(model.liveRateBusy) }
                    Text("10–\(model.launchRateFPS) fps; fractional rates such as 59.94 are supported.").font(.caption).foregroundStyle(.secondary)
                } else { Text(model.liveHTTPBitrate ? "This host offers bitrate-only controls." : "This stream has not offered live rate controls.").foregroundStyle(.secondary) }
                Button("Apply to Current Stream") {
                    guard let kbps else { return }
                    let rate=model.liveRateAvailable ? (milliHz ?? 0) : 0
                    let context=model.hostSessionContextID
                    Task { await model.changeLiveRates(kbps:kbps,fpsMilliHz:rate,context:context) }
                }.disabled(!model.canChangeLiveRates || kbps == nil || (model.liveRateAvailable && milliHz == nil))
                if model.liveRateBusy { ProgressView("Waiting for host…") }
            }
            Text(model.liveRateMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Changes apply to this stream. Saved game settings stay the same; reconnect restores them and automatic bitrate.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { bitrate=String(Double(model.appliedLiveKbps ?? model.launchRateKbps)/1000);fps=String(Double(model.appliedLiveFPS ?? model.launchRateFPS*1000)/1000) }
    }
}
