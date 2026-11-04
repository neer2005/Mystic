import SwiftUI
import MysticCore

struct GameVideoPreferencesView: View {
    @Bindable var model: ConnectionModel
    @State private var hostEditor: HostEditor?
    private struct HostEditor: Identifiable { let id: String;let name: String }
    private var locked: Bool { model.hasSession || model.isBusy || model.hostProfileKey == nil }
    var body: some View {
        Group {
            Picker("Settings",selection:$model.gameVideoSource) {
                ForEach(GameVideoSource.allCases,id:\.self) { source in Text(source.label).tag(source) }
            }.disabled(locked)
            if model.gameVideoSource == .custom {
                VideoSettingsFields(value:Binding(get:{ model.effectiveVideoSettings },set:{ model.updateGameVideo($0) }),locked:locked,host:model.host?.display)
                Text("Saved for this game on this host. Choosing inherited settings removes this game's custom video settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // The summary keeps Start Stream within reach; the inherited values are one click away.
                // It shows what streams get, which the renderer and notch mode limit.
                let video=model.effectiveVideoSettings.limited(to:model.videoOutput)
                LabeledContent("Stream",value:Self.summary(video))
                DisclosureGroup("Details") {
                    LabeledContent("Resolution",value:StreamPreferences.resolutionLabel(video.resolution))
                    LabeledContent("Frame Rate",value:StreamPreferences.frameRateLabel(video.fps))
                    LabeledContent("Codec",value:Self.codec(video))
                    LabeledContent("Bitrate",value:"\(StreamPreferences.bitrateLabel(video.bitrateMbps))\(video.adaptiveBitrate ? " maximum · automatic" : "")")
                    LabeledContent("HDR",value:video.hdr ? "On" : "Off")
                    LabeledContent("Frame Pacing",value:video.framePacing.label)
                    if video.virtualDisplay || video.hostDisplay != .hostDefault {
                        LabeledContent("PC Display",value:video.hostDisplay == .hostDefault ? "Virtual Display" : video.hostDisplay.label)
                    }
                    Text(model.gameVideoSource == .global ? "Follows Settings → Video, including future changes." :
                        "Follows this host's defaults, or global defaults when the host has no custom settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Edit Host Defaults…") {
                if let key=model.hostProfileKey { hostEditor=HostEditor(id:key,name:model.host?.name ?? "Host") }
            }.disabled(locked).sheet(item:$hostEditor) { target in
                HostVideoPreferencesView(model:model,hostKey:target.id,hostName:target.name)
            }
            if let error=model.profiles.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.environment(\.videoOutput,model.videoOutput)
    }
    static func codec(_ video: StreamVideoSettings) -> String { video.codec == "auto" ? "Automatic" : video.codec == "h264" ? "H.264" : video.codec.uppercased() }
    /// For example "3024 × 1890 · 120 fps · HEVC · HDR".
    static func summary(_ video: StreamVideoSettings) -> String {
        [StreamPreferences.resolutionLabel(video.resolution),StreamPreferences.frameRateLabel(video.fps),video.codec == "auto" ? "Auto codec" : codec(video),video.hdr ? "HDR" : "SDR"]
            .joined(separator:" · ")
    }
}

private struct HostVideoPreferencesView: View {
    @Bindable var model: ConnectionModel
    let hostKey: String
    let hostName: String
    @Environment(\.dismiss) private var dismiss
    private var locked: Bool { model.hasSession || model.isBusy || model.hostProfileKey != hostKey }
    private var usesGlobal: Binding<Bool> {
        Binding(get:{ model.profiles.value.hostVideo(for:hostKey) == nil },set:{ useGlobal in
            model.updateHostVideo(useGlobal ? nil : model.settings.value.videoSettings,hostKey:hostKey)
        })
    }
    var body: some View {
        VStack(spacing:0) {
            Form {
                Section("Video defaults for \(hostName)") {
                    Toggle("Use global defaults",isOn:usesGlobal).disabled(locked)
                    if !usesGlobal.wrappedValue {
                        VideoSettingsFields(value:Binding(get:{ model.profiles.value.hostVideo(for:hostKey) ?? model.settings.value.videoSettings },
                            set:{ model.updateHostVideo($0,hostKey:hostKey) }),locked:locked,host:model.host?.display)
                    }
                    Text("Games set to use host defaults follow these settings. Custom game settings and explicit global choices are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error=model.profiles.error { Text(error).foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Spacer();Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }.frame(width:520,height:550)
    }
}
