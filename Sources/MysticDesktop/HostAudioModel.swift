import Observation
import SwiftUI
import MysticKit

/// The host's night mode and headphone surround: read each time the panel opens, so they show the
/// PC's state, and changed live for this stream.
@MainActor @Observable
public final class HostAudioModel {
    public private(set) var switches: [HostAudioSwitch]=[]
    public private(set) var problem: String?
    public private(set) var busy=false
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }
    func refresh() async {
        guard !busy,model.phase == .streaming,let connection=model.connection else { return }
        let token=model.generation
        busy=true
        defer { if model.generation == token { busy=false } }
        do {
            let value=try await connection.hostAudio()
            guard model.generation == token else { return }
            switches=value;problem=nil
        } catch {
            guard model.generation == token else { return }
            // Nothing stale stays on screen.
            switches=[];problem="The PC's audio settings could not be read."
        }
    }
    func set(_ id: String,on: Bool) async {
        guard !busy,model.phase == .streaming,let connection=model.connection else { return }
        let token=model.generation
        busy=true
        defer { if model.generation == token { busy=false } }
        do {
            let value=try await connection.setHostAudio(id:id,on:on)
            guard model.generation == token else { return }
            switches=value;problem=nil
        } catch {
            guard model.generation == token else { return }
            problem="Could not change the PC's audio: \(error.localizedDescription)"
        }
    }
    func reset() { switches=[];problem=nil;busy=false }
}

struct HostAudioView: View {
    let audio: HostAudioModel
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if !audio.switches.isEmpty || audio.problem != nil { Text("Sound on the PC").font(.headline) }
            ForEach(audio.switches) { item in
                Toggle(item.label,isOn:Binding(get:{ item.on },set:{ on in Task { await audio.set(item.id,on:on) } }))
                    .disabled(!item.enabled || audio.busy)
                if let note=item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            if let problem=audio.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .task { await audio.refresh() }
    }
}
