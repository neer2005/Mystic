import SwiftUI
import MysticCore

public struct MysticSettingsView: View {
    @Bindable private var model: ConnectionModel
    public init(model: ConnectionModel) { self.model=model }
    public var body: some View {
        VStack(spacing:0) {
            TabView(selection:setting(\.settingsPane)) {
                Form {
                    Section("Library") {
                        Picker("View",selection:setting(\.libraryLayout)) { Text("Grid").tag("grid");Text("List").tag("list") }
                        Picker("Sort Apps",selection:setting(\.librarySort)) { Text("Name").tag("name");Text("Host Order").tag("host") }
                    }
                    Section("Streaming") {
                        Toggle("Show Latency HUD",isOn:$model.showLatencyHUD)
                        Toggle("Sync Clipboard Text",isOn:$model.clipboardSync).disabled(model.hasSession || model.isBusy)
                        Text("Off by default. Shares new plain-text copies only while the stream window is active. Files and images stay on the Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Text("Choose a host from the library sidebar to start. Interrupted streams can reconnect automatically when enabled in Network.").foregroundStyle(.secondary) }
                }.tabItem { Label("General",systemImage:"gearshape") }.tag("general")
                Form {
                    Section("Stream Defaults") { VideoPreferencesView(model:model) }
                    Section { Text("Only hardware-verified formats can start a stream. HDR also requires support from the selected host app.").foregroundStyle(.secondary) }
                }.tabItem { Label("Video",systemImage:"display") }.tag("video")
                Form {
                    Section("Playback") { AudioPreferencesView(model:model) }
                    Section { Text("Volume and mute apply immediately. Surround host audio is mixed to stereo on this Mac.").foregroundStyle(.secondary) }
                }.tabItem { Label("Audio",systemImage:"speaker.wave.2") }.tag("audio")
                Form {
                    Section("Stream Recovery") {
                        Toggle("Reconnect Interrupted Streams",isOn:$model.automaticReconnect)
                            .disabled(model.hasSession || model.isBusy)
                        Text("Retries a dropped stream for up to one minute. Disconnect cancels recovery.").foregroundStyle(.secondary)
                    }
                    Section("Host Discovery") {
                        Toggle("Discover Hosts on the Local Network",isOn:setting(\.discoveryEnabled))
                        Text(model.discovery.status).font(.caption).foregroundStyle(.secondary)
                        Text("Hosts outside your LAN can be added by address. Discovery does not connect or pair automatically.").foregroundStyle(.secondary)
                    }
                }.tabItem { Label("Network",systemImage:"network") }.tag("network")
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Restore Defaults") { model.settings.restoreDefaults() }.disabled(model.hasSession || model.isBusy)
                Spacer()
                if let error=model.settings.error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(16)
        }
        .frame(width:560,height:440)
        .onChange(of:model.settings.value) { model.applyLiveSettings() }
    }
    private func setting<T>(_ key: WritableKeyPath<StreamPreferences,T>) -> Binding<T> {
        Binding(get:{ model.settings.value[keyPath:key] },set:{ value in model.settings.update { $0[keyPath:key]=value } })
    }
}

struct VideoPreferencesView: View {
    @Bindable var model: ConnectionModel
    private var locked: Bool { model.hasSession || model.isBusy }
    var body: some View {
        Group {
            Picker("Resolution",selection:$model.resolution) {
                ForEach(StreamPreferences.resolutions,id:\.self) { resolution in
                    Text(StreamPreferences.resolutionLabel(resolution)).tag(resolution)
                }
            }
            Picker("Frame Rate",selection:$model.fps) { Text("60 fps").tag(UInt32(60));Text("120 fps").tag(UInt32(120)) }
            Picker("Frame Pacing",selection:$model.framePacing) {
                ForEach(FramePacingMode.allCases,id:\.self) { mode in Text(mode.label).tag(mode) }
            }
            Text(model.framePacing == .lowLatency ? "Presents decoded frames without intentional buffering." : "Uses about one frame of buffering to absorb arrival jitter.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Codec",selection:$model.codec) {
                Text("Automatic").tag("auto");Text("H.264").tag("h264");Text("HEVC").tag("hevc");Text("AV1").tag("av1")
            }
            Stepper("Bitrate: \(model.bitrateMbps) Mbps",value:$model.bitrateMbps,in:5...150,step:5)
            Toggle("Automatic Bitrate",isOn:$model.adaptiveBitrate)
            if model.adaptiveBitrate {
                Text("Adjusts bitrate up to the selected limit when the host supports live changes.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("HDR",isOn:$model.hdr)
            Text("Requests 10-bit HDR from supported host apps. HDR video uses the stream window’s display; macOS maps it to SDR on displays without HDR headroom.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(locked)
    }
}

struct AudioPreferencesView: View {
    @Bindable var model: ConnectionModel
    var body: some View {
        Picker("Host Channels",selection:$model.audioLayout) {
            Text("Stereo").tag("stereo");Text("5.1 → Stereo").tag("5.1");Text("7.1 → Stereo").tag("7.1")
        }.disabled(model.hasSession || model.isBusy)
        Toggle("Mute",isOn:$model.muted)
        Slider(value:$model.volume,in:0...1) { Text("Volume") }
        Toggle("Use Mac Microphone",isOn:$model.microphoneEnabled).disabled(model.hasSession || model.isBusy)
        if model.microphoneEnabled {
            Toggle("Mute Microphone",isOn:$model.microphoneMuted)
            Text(model.microphoneStatus).font(.caption).foregroundStyle(.secondary)
        }
        Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
    }
}
