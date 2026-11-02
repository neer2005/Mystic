import AppKit
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
                        Toggle("Show Performance Overlay",isOn:$model.showLatencyHUD)
                        Picker("Overlay Detail",selection:$model.overlayMode) {
                            ForEach(OverlayMode.allCases,id:\.self) { Text($0.label).tag($0) }
                        }
                        Text("Compact shows frame rate, round trip and loss behind a health mark. Statistics adds the stream, video, host and decode lines, with the host's CPU and GPU where it reports them. Debug adds every timing.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Sync Clipboard Text",isOn:$model.clipboardSync).disabled(model.hasSession || model.isBusy)
                        Text("Off by default. Shares new plain-text copies only while the stream window is active. Files and images stay on the Mac.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Local Cursor",isOn:$model.localCursor)
                        Text("In desktop control, the host's cursor becomes the Mac pointer, so it moves without video delay. Needs a host that sends its cursor; Sunshine-based hosts and Rubylight with cursor shapes do.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Library") {
                        Toggle("Quick Resume",isOn:$model.quickResume)
                        Text("Choosing a PC that is running a game goes straight back into the game instead of opening its library.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Updates") {
                        Toggle("Check for Updates",isOn:$model.checkForUpdates)
                        Text("Once per launch, Mystic asks GitHub whether a newer release is out and links to its page. Nothing is downloaded or installed. \(model.updates.status).").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Text("Choose a host from the library sidebar to start. Interrupted streams can reconnect automatically when enabled in Network.").foregroundStyle(.secondary) }
                }.tabItem { Label("General",systemImage:"gearshape") }.tag("general")
                Form {
                    Section("Stream Defaults") { VideoPreferencesView(model:model) }
                    Section("Picture") {
                        Picker("Renderer",selection:$model.videoRenderer) {
                            ForEach(VideoRendererKind.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(model.hasSession || model.isBusy)
                        Picker("Video Size",selection:$model.videoSizing) {
                            ForEach(VideoSizing.allCases,id:\.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Align Video to Top",isOn:$model.alignVideoTop).disabled(model.videoSizing == .fill || model.videoSizing == .stretch)
                        Text("Applies at once, also during a stream. Fit keeps the whole picture, Fill crops to cover the window, Stretch changes its shape, and Native Pixels shows one video pixel on one display pixel.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Text("These are global defaults. Choose host or game settings in Stream Details to override them. Only hardware-verified formats can start a stream; HDR also requires support from the host app.").foregroundStyle(.secondary) }
                }.tabItem { Label("Video",systemImage:"display") }.tag("video")
                Form {
                    Section("Playback") { AudioPreferencesView(model:model) }
                    Section { Text("Volume and mute apply immediately. Surround plays on a configured multichannel output, with stereo fallback for other devices.").foregroundStyle(.secondary) }
                }.tabItem { Label("Audio",systemImage:"speaker.wave.2") }.tag("audio")
                Form {
                    Section("Mouse") {
                        Stepper("Mouse Speed: \(model.inputPreferences.mouseSpeedPercent)%",value:$model.inputPreferences.mouseSpeedPercent,in:25...400,step:25)
                        Toggle("Send Back and Forward Buttons",isOn:$model.inputPreferences.mouseNavigationButtons)
                        Text("Mouse speed is the captured pointer's sensitivity; desktop control follows the Mac's pointer.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Controllers") {
                        Toggle("Use Controllers",isOn:$model.inputPreferences.controllers)
                        Toggle("Nintendo Button Layout",isOn:$model.inputPreferences.swapFaceButtons)
                        Toggle("Motion Controls",isOn:$model.inputPreferences.controllerMotion)
                        Toggle("Disable Vibration",isOn:$model.inputPreferences.disableVibration)
                        Stepper("Stick Dead Zone: \(model.inputPreferences.stickDeadZonePercent)%",value:$model.inputPreferences.stickDeadZonePercent,in:0...50)
                        Text("Every connected controller becomes a controller on the PC. The Nintendo layout swaps A with B and X with Y. Motion controls send the gyro and accelerometer when a game asks for them.").font(.caption).foregroundStyle(.secondary)
                    }
                }.tabItem { Label("Controls",systemImage:"gamecontroller") }.tag("controls")
                KeyboardSettingsView(model:model)
                    .tabItem { Label("Keyboard",systemImage:"keyboard") }.tag("keyboard")
                Form {
                    Section("Stream Recovery") {
                        Toggle("Reconnect Interrupted Streams",isOn:$model.automaticReconnect)
                            .disabled(model.hasSession || model.isBusy)
                        Text("Retries a dropped stream for up to one minute. Disconnect cancels recovery.").foregroundStyle(.secondary)
                    }
                    Section("Network Drops") {
                        Picker("Ride Out Network Drops",selection:$model.networkGrace) {
                            ForEach(NetworkGrace.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(model.hasSession || model.isBusy)
                        Text("Keeps a stream through a silent network for this long instead of ending it. The picture freezes and held keys are released until the host answers. The host must wait as long too; Sunshine-based hosts call this ping_timeout.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Error Correction") {
                        Picker("Error Correction",selection:$model.errorCorrection) {
                            ForEach(ErrorCorrection.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(model.hasSession || model.isBusy)
                        Text("Host's Setting leaves the share of recovery data to the host. Automatic follows the video loss this Mac reports each second. Rubylight and Sunshine-based hosts that accept the request use it; other hosts keep their own.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Link Hints") {
                        Toggle("Tell the Host When on Wi-Fi",isOn:$model.tellHostWireless)
                        Toggle("Tell the Host the Wired Link Speed",isOn:$model.tellHostLinkSpeed)
                        Text("A Rubylight host paces video for Wi-Fi from the first frame. A wired link speed lets any host cap its sending rate. Over a VPN, the Mac's own connection decides.")
                            .foregroundStyle(.secondary)
                    }.disabled(model.hasSession || model.isBusy)
                    Section("Wi-Fi") {
                        Toggle("Keep AWDL Off While Streaming",isOn:$model.holdAWDL)
                        switch model.awdl.status {
                        case .needsApproval:
                            LabeledContent("Mystic's helper needs your approval in System Settings.") {
                                Button("Open Login Items…") { model.awdl.openApproval() }
                            }
                        case .unavailable(let reason): Text(reason).foregroundStyle(.secondary)
                        case .off,.ready: EmptyView()
                        }
                        Text("AWDL is the Wi-Fi link behind AirDrop and Continuity, and can stall a stream's packets. This installs a small helper that holds it down only during a stream over Wi-Fi, so those features pause for that time.")
                            .foregroundStyle(.secondary)
                    }
                    .onAppear { model.awdl.refresh() }
                    .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in model.awdl.refresh() }
                    Section("Network Profiles") { NetworkProfilesView(model:model) }.disabled(model.hasSession || model.isBusy)
                    Section("Network Changes") {
                        Toggle("Keep Streams When the Network Changes",isOn:$model.clientRoaming)
                        Toggle("Also onto Metered Networks",isOn:$model.roamingOnMeteredNetworks).disabled(!model.clientRoaming)
                        Text("Moves a stream to a new network, such as from Wi-Fi to Ethernet, with hosts that support client roaming. Metered networks include iPhone hotspots. On any host, a stream whose network comes back on a new address reconnects at once.")
                            .foregroundStyle(.secondary)
                    }.disabled(model.hasSession || model.isBusy)
                    Section("Host Discovery") {
                        Toggle("Discover Hosts on the Local Network",isOn:setting(\.discoveryEnabled))
                        Text(model.discovery.status).font(.caption).foregroundStyle(.secondary)
                        Text("Hosts outside your LAN can be added by address. Discovery does not connect or pair automatically.").foregroundStyle(.secondary)
                    }
                }.tabItem { Label("Network",systemImage:"network") }.tag("network")
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Restore Global Defaults") { model.settings.restoreDefaults() }.disabled(model.hasSession || model.isBusy)
                    .help("Resets global settings. Saved host and game profiles are kept.")
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
    var body: some View {
        VideoSettingsFields(value:Binding(get:{ model.settings.value.videoSettings },
            set:{ video in model.settings.update { $0.videoSettings=video } }),
            locked:model.hasSession || model.isBusy)
    }
}

struct VideoSettingsFields: View {
    @Binding var value: StreamVideoSettings
    var locked: Bool
    /// What this settings' host reports; nil for global settings, which offer every row.
    var host: HostDisplaySupport? = nil
    /// What Recommended comes to for these settings on this Mac's screen.
    private var recommended: StreamMode {
        var video=value;video.bitrateMbps=StreamPreferences.recommendedBitrate
        return video.mode(displayPixels:NSScreen.main.map(DisplayRefresh.pixels),displayHertz:NSScreen.main.map(DisplayRefresh.hertz))
    }
    var body: some View {
        Group {
            ResolutionField(resolution:$value.resolution)
            FrameRateField(fps:$value.fps)
            Picker("Frame Pacing",selection:$value.framePacing) {
                ForEach(FramePacingMode.allCases,id:\.self) { mode in Text(mode.label).tag(mode) }
            }
            Text(value.framePacing.detail)
                .font(.caption).foregroundStyle(.secondary)
            Picker("Codec",selection:$value.codec) {
                Text("Automatic").tag("auto");Text("H.264").tag("h264");Text("HEVC").tag("hevc");Text("AV1").tag("av1")
            }
            BitrateField(bitrateMbps:$value.bitrateMbps,recommended:recommended)
            Toggle("Automatic Bitrate",isOn:$value.adaptiveBitrate)
            if value.adaptiveBitrate {
                Text("Adjusts bitrate up to the selected limit when the host supports live changes.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Automatic Quality",selection:$value.automaticQuality) {
                ForEach(AutomaticQuality.allCases,id:\.self) { Text($0.label).tag($0) }
            }
            if value.automaticQuality != .off {
                Stepper("Minimum Resolution: \(value.qualityMinShortEdge)p",value:$value.qualityMinShortEdge,in:256...2160,step:60)
                Stepper("Minimum Frame Rate: \(value.qualityMinFps) fps",value:$value.qualityMinFps,in:15...240,step:5)
                Text("Lowers resolution or frame rate during a stream when this Mac or the network cannot keep up, and restores them when it can, never below these minimums or above the stream's own. Automatic bitrate answers network trouble first. Needs a host that accepts size changes, such as Rubylight.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("HDR",isOn:$value.hdr)
            Text("Requests 10-bit HDR from supported host apps. HDR video uses the stream window’s display; macOS maps it to SDR on displays without HDR headroom.")
                .font(.caption).foregroundStyle(.secondary)
            PCDisplayFields(value:$value,host:host)
        }.disabled(locked)
    }
}

struct AudioPreferencesView: View {
    @Bindable var model: ConnectionModel
    var body: some View {
        Picker("Host Channels",selection:$model.audioLayout) {
            Text("Stereo").tag("stereo");Text("5.1").tag("5.1");Text("7.1").tag("7.1")
        }.disabled(model.hasSession || model.isBusy)
        Toggle("Mute",isOn:$model.muted)
        Slider(value:$model.volume,in:0...1) { Text("Volume") }
        Toggle("Play Audio on the PC Too",isOn:$model.playAudioOnHost).disabled(model.hasSession || model.isBusy)
        Toggle("Use Mac Microphone",isOn:$model.microphoneEnabled).disabled(model.hasSession || model.isBusy)
        if model.microphoneEnabled {
            Toggle("Mute Microphone",isOn:$model.microphoneMuted)
            Text(model.microphoneStatus).font(.caption).foregroundStyle(.secondary)
        }
        Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
        if model.canRetryAudio { Button("Retry Audio") { model.retryAudioOutput() } }
    }
}
