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
        guard let n=Double(fps),n.isFinite,n >= 10,n <= Double(model.rates.launchFPS),n <= 240 else { return nil }
        return UInt32((n*1000).rounded())
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Live Stream Rates").font(.headline)
            if model.phase != .streaming { Text("Start a stream to change bitrate and frame rate.").foregroundStyle(.secondary) }
            else {
                if let applied=model.rates.appliedKbps { LabeledContent("Host-confirmed bitrate",value:"\(applied) kbps") }
                if let applied=model.rates.appliedFPS { LabeledContent("Host-confirmed frame rate",value:String(format:"%.3f fps",Double(applied)/1000)) }
                if model.rates.appliedKbps == nil { Text("Launch request: \(model.rates.launchKbps) kbps · \(model.rates.launchFPS) fps").font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Bitrate (Mbps)") { TextField("Bitrate (Mbps)",text:$bitrate).textFieldStyle(.roundedBorder).frame(width:130).disabled(model.rates.busy) }
                Text("1–150 Mbps").font(.caption).foregroundStyle(.secondary)
                if model.rates.liveAvailable {
                    LabeledContent("Frame rate (fps)") { TextField("Frame rate (fps)",text:$fps).textFieldStyle(.roundedBorder).frame(width:130).disabled(model.rates.busy) }
                    Text("10–\(model.rates.launchFPS) fps; fractional rates such as 59.94 are supported.").font(.caption).foregroundStyle(.secondary)
                } else { Text(model.rates.httpBitrate ? "This host offers bitrate-only controls." : "This stream has not offered live rate controls.").foregroundStyle(.secondary) }
                Button("Apply to Current Stream") {
                    guard let kbps else { return }
                    let rate=model.rates.liveAvailable ? (milliHz ?? 0) : 0
                    let context=model.contextID
                    Task { await model.rates.change(kbps:kbps,fpsMilliHz:rate,context:context) }
                }.disabled(!model.rates.canChange || kbps == nil || (model.rates.liveAvailable && milliHz == nil))
                if model.rates.busy { ProgressView("Waiting for host…") }
            }
            Text(model.rates.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Changes apply to this stream. Saved game settings stay the same; reconnect restores them and automatic bitrate.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { bitrate=String(Double(model.rates.appliedKbps ?? model.rates.launchKbps)/1000);fps=String(Double(model.rates.appliedFPS ?? model.rates.launchFPS*1000)/1000) }
    }
}
