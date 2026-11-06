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
                        Picker("Sort Games",selection:setting(\.librarySort)) { Text("Name").tag("name");Text("PC's Order").tag("host") }
                        Toggle("Quick Resume",isOn:$model.quickResume)
                        Text("Choosing a PC that is already running a game goes straight back into it.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Streaming") {
                        Toggle("Show Performance Overlay",isOn:$model.showLatencyHUD)
                        Picker("Overlay Detail",selection:$model.overlayMode) {
                            ForEach(OverlayMode.allCases,id:\.self) { Text($0.label).tag($0) }
                        }
                        Text("Compact shows frame rate, network delay and packet loss. Statistics adds video, PC and decode figures. Debug adds every timing.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Sync Clipboard Text",isOn:$model.clipboardSync).disabled(model.hasSession || model.isBusy)
                        Text("Shares text you copy while the stream window is active. Files and images stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Local Cursor",isOn:$model.localCursor)
                        Text("When you control the desktop, the PC's cursor becomes the Mac pointer, so it moves without video delay. Needs a PC that sends its cursor.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Updates") {
                        Toggle("Check for Updates",isOn:$model.checkForUpdates)
                        Text("At launch, Mystic checks for a newer release and links to it. Nothing is downloaded or installed. \(model.updates.status).").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        LabeledContent("All Settings") {
                            Button("Restore Defaults") { model.settings.restoreDefaults() }.disabled(model.hasSession || model.isBusy)
                        }
                        Text("Resets every setting here. Settings saved for a PC or a game are kept.").font(.caption).foregroundStyle(.secondary)
                        if let error=model.settings.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }.tabItem { Label("General",systemImage:"gearshape") }.tag("general")
                Form {
                    Section("Stream Defaults") { VideoPreferencesView(model:model) }
                    Section("Picture") {
                        Toggle("V-Sync",isOn:$model.vsync).disabled(model.hasSession || model.isBusy || model.framePacing.forcesVsync)
                        Text("Turning it off shows each picture at once with Lowest Latency on Metal: less delay, but the picture may tear. The other pacing modes always wait for the display.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Renderer",selection:$model.videoRenderer) {
                            ForEach(VideoRendererKind.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(model.hasSession || model.isBusy)
                        if model.videoRenderer == .metal {
                            Text("Metal stays below a MacBook Pro's camera and fits HDR to the screen itself, so in full screen the display takes its pictures directly, without macOS compositing them. The performance overlay is drawn over the picture, so macOS composites while it shows.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Full Screen Around the Camera",isOn:model.videoRenderer == .metal ? .constant(false) : $model.notchFullScreen)
                            .disabled(model.hasSession || model.isBusy || model.videoRenderer == .metal)
                        Text(model.videoRenderer == .metal ? "Off with the Metal renderer, which stays below the camera."
                             : "On a MacBook Pro, full-display sizes such as 3024 × 1964 fill the screen to its top edge, as on the PC's panel. macOS composites every frame of this full screen, which adds delay; off, they stream at the size below the camera.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Video Size",selection:$model.videoSizing) {
                            ForEach(VideoSizing.allCases,id:\.self) { Text($0.label).tag($0) }
                        }
                        Toggle("Align Video to Top",isOn:$model.alignVideoTop).disabled(model.videoSizing == .fill || model.videoSizing == .stretch)
                        Text("Fit keeps the whole picture, Fill crops to cover the window, Stretch changes its shape, and Native Pixels maps each video pixel to one display pixel.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section { Text("These are the defaults. A PC or a game can have its own settings, chosen next to the library.").font(.caption).foregroundStyle(.secondary) }
                }.tabItem { Label("Video",systemImage:"display") }.tag("video")
                Form {
                    Section("Playback") { AudioPreferencesView(model:model) }
                    Section { Text("Surround plays on a multichannel output set up in Audio MIDI Setup; other outputs play stereo.").font(.caption).foregroundStyle(.secondary) }
                }.tabItem { Label("Audio",systemImage:"speaker.wave.2") }.tag("audio")
                Form {
                    Section("Mouse") {
                        Stepper("Mouse Speed: \(model.inputPreferences.mouseSpeedPercent)%",value:$model.inputPreferences.mouseSpeedPercent,in:25...400,step:25)
                        Toggle("Send Back and Forward Buttons",isOn:$model.inputPreferences.mouseNavigationButtons)
                        Text("Mouse Speed applies to a captured mouse. Controlling the desktop follows the Mac's pointer speed.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Instant Mouse Input",isOn:$model.instantMouseInput).disabled(model.hasSession || model.isBusy)
                        Text("Sends mouse movement right away instead of in small batches.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Controllers") {
                        Toggle("Use Controllers",isOn:$model.inputPreferences.controllers)
                        Toggle("Nintendo Button Layout",isOn:$model.inputPreferences.swapFaceButtons)
                        Toggle("Motion Controls",isOn:$model.inputPreferences.controllerMotion)
                        Toggle("Disable Vibration",isOn:$model.inputPreferences.disableVibration)
                        Stepper("Stick Dead Zone: \(model.inputPreferences.stickDeadZonePercent)%",value:$model.inputPreferences.stickDeadZonePercent,in:0...50)
                        Text("Each connected controller appears on the PC. The Nintendo layout swaps A with B and X with Y.").font(.caption).foregroundStyle(.secondary)
                        Picker("Hold Guide to Release Input",selection:$model.inputPreferences.guideHoldMillis) {
                            ForEach(GuideHold.choices,id:\.self) { ms in Text(ms == 0 ? "Off" : "\(Double(ms)/1000,format:.number) s").tag(ms) }
                        }
                        Text("Gives the Mac its mouse and keyboard back, as ⌃⌥⇧Esc does, so the window's controls are in reach. A short press still goes to the PC.").font(.caption).foregroundStyle(.secondary)
                        Picker("Buttons to Leave the Stream",selection:$model.inputPreferences.leaveCombo) {
                            ForEach(ControllerLeaveCombo.allCases,id:\.self) { Text($0.label).tag($0) }
                        }
                        Text("Hold these buttons together to leave the stream. Pick others if a game or your controller needs these.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Controller Mouse") {
                        Toggle("Controller Mouse Mode",isOn:$model.inputPreferences.controllerMouse)
                        Text("Hold Start for 750 ms, then let go, to move the PC's pointer with the controller. A and B click, the D-pad scrolls.").font(.caption).foregroundStyle(.secondary)
                        Picker("Stick for Scrolling",selection:$model.inputPreferences.scrollStick) {
                            ForEach(ControllerMouse.ScrollStick.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(!model.inputPreferences.controllerMouse)
                        Text("In controller mouse mode this stick scrolls and the other moves the pointer. Off lets both sticks move it.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Precise Controller Mouse",isOn:$model.inputPreferences.preciseControllerMouse).disabled(!model.inputPreferences.controllerMouse)
                        Text("In controller mouse mode, hold X to move in fixed pixel steps. Press Y to double the step, from 1 to 128 pixels.").font(.caption).foregroundStyle(.secondary)
                    }
                }.tabItem { Label("Controls",systemImage:"gamecontroller") }.tag("controls")
                KeyboardSettingsView(model:model)
                    .tabItem { Label("Keyboard",systemImage:"keyboard") }.tag("keyboard")
                Form {
                    Section("Stream Recovery") {
                        Toggle("Reconnect Interrupted Streams",isOn:$model.automaticReconnect)
                            .disabled(model.hasSession || model.isBusy)
                        Text("Retries a dropped stream for up to one minute.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Network Drops") {
                        Picker("Ride Out Network Drops",selection:$model.networkGrace) {
                            ForEach(NetworkGrace.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(model.hasSession || model.isBusy)
                        Text("Keeps a stream alive through a network drop for this long. The picture freezes and held keys are released until the PC answers. The PC's own timeout must be at least this long.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Error Correction") {
                        Picker("Error Correction",selection:$model.errorCorrection) {
                            ForEach(ErrorCorrection.allCases,id:\.self) { Text($0.label).tag($0) }
                        }.disabled(model.hasSession || model.isBusy)
                        Text("Extra data the PC sends so lost packets can be rebuilt. Automatic follows the loss this Mac sees. PCs that don't take the request keep their own setting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Bitrate") {
                        Toggle("Lower Bitrate When Frames Are Lost",isOn:$model.lowerBitrateOnLoss)
                        Text("Turns the bitrate down as soon as frames go missing, and back up after a few clean seconds. Works with PCs that can change the bitrate during a stream, and replaces Automatic Bitrate there.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Test the Link Before Starting",isOn:$model.testLinkBeforeStart)
                        Text("A new stream at the Recommended bitrate first measures the connection to the PC and starts no higher than it holds. Works with PCs that support it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.hasSession || model.isBusy)
                    Section("Link Hints") {
                        Toggle("Tell the Host When on Wi-Fi",isOn:$model.tellHostWireless)
                        Toggle("Tell the Host the Wired Link Speed",isOn:$model.tellHostLinkSpeed)
                        Text("Helps the PC pace video for your connection from the first frame.")
                            .font(.caption).foregroundStyle(.secondary)
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
                        Text("AWDL is the Wi-Fi link behind AirDrop and Continuity, and can stall a stream. This installs a small helper that turns it off during Wi-Fi streams, so those features pause until the stream ends.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .onAppear { model.awdl.refresh() }
                    .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in model.awdl.refresh() }
                    Section("Network Profiles") { NetworkProfilesView(model:model) }.disabled(model.hasSession || model.isBusy)
                    Section("Network Changes") {
                        Toggle("Keep Streams When the Network Changes",isOn:$model.clientRoaming)
                        Toggle("Also onto Metered Networks",isOn:$model.roamingOnMeteredNetworks).disabled(!model.clientRoaming)
                        Text("Moves a stream to a new network, such as from Wi-Fi to Ethernet, where the PC supports it. Metered networks include iPhone hotspots.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(model.hasSession || model.isBusy)
                    Section("Host Discovery") {
                        Toggle("Find PCs on the Local Network",isOn:setting(\.discoveryEnabled))
                        Text(model.discovery.status).font(.caption).foregroundStyle(.secondary)
                        Text("PCs elsewhere can be added by address. Finding a PC never connects or pairs with it.").font(.caption).foregroundStyle(.secondary)
                    }
                }.tabItem { Label("Network",systemImage:"network") }.tag("network")
            }.formStyle(.grouped)
        }
        .frame(width:620,height:640)
        .environment(\.videoOutput,model.videoOutput)
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
    @Environment(\.videoOutput) private var output
    private var renderer: VideoRendererKind { output.renderer }
    var locked: Bool
    /// What this settings' host reports; nil for global settings, which offer every row.
    var host: HostDisplaySupport? = nil
    /// What Recommended comes to for these settings on this Mac's screen.
    private var recommended: StreamMode {
        var video=value.limited(to:output);video.bitrateMbps=StreamPreferences.recommendedBitrate
        return video.mode(displayPixels:NSScreen.main.map { DisplayRefresh.pixels($0,belowCamera:!output.coversNotch) },displayHertz:NSScreen.main.map(DisplayRefresh.hertz))
    }
    private var streamsHDR: Bool { value.limited(to:output).hdr }
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
                Text("Adjusts bitrate up to this limit when the PC supports live changes.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Automatic Quality",selection:$value.automaticQuality) {
                ForEach(AutomaticQuality.allCases,id:\.self) { Text($0.label).tag($0) }
            }
            if value.automaticQuality != .off {
                Stepper("Minimum Resolution: \(value.qualityMinShortEdge)p",value:$value.qualityMinShortEdge,in:256...2160,step:60)
                Stepper("Minimum Frame Rate: \(value.qualityMinFps) fps",value:$value.qualityMinFps,in:15...240,step:5)
                Text("Lowers resolution or frame rate when this Mac or the network can't keep up, never below these minimums. Needs a PC that accepts size changes.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("HDR",isOn:$value.hdr)
            Text(renderer == .metal ? "Needs a game and PC with HDR. Metal fits the picture's highlights to what this screen can show right now."
                 : "Needs a game and PC with HDR. On displays without HDR, macOS maps the picture to SDR.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Prefer YUV 4:4:4",isOn:$value.preferYUV444).disabled(streamsHDR)
            Text(streamsHDR ? "HDR takes priority." : "Sharper colored text where the PC and this Mac support it. Can't be combined with 10-bit color.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("10-bit Color (SDR)",isOn:$value.tenBitSDR).disabled(streamsHDR)
            Text(streamsHDR ? "HDR is already 10-bit and takes priority." : "Reduces banding in gradients. Needs a PC that offers it, with its display in SDR.")
                .font(.caption).foregroundStyle(.secondary)
            PCDisplayFields(value:$value,host:host)
        }.disabled(locked)
    }
}

struct AudioPreferencesView: View {
    @Bindable var model: ConnectionModel
    var body: some View {
        Picker("Channels",selection:$model.audioLayout) {
            Text("Stereo").tag("stereo");Text("5.1").tag("5.1");Text("7.1").tag("7.1")
        }.disabled(model.hasSession || model.isBusy)
        Toggle("Mute",isOn:$model.muted)
        Slider(value:$model.volume,in:0...1) { Text("Volume") }
        Toggle("Play Audio on the PC Too",isOn:$model.playAudioOnHost).disabled(model.hasSession || model.isBusy)
        Toggle("Uncompressed Audio",isOn:$model.uncompressedAudio).disabled(model.hasSession || model.isBusy)
        Text("Asks the PC for lossless sound instead of compressed audio. Uses 1.5 Mbps for stereo, up to 6 Mbps for 7.1. PCs that don't support it keep sending compressed audio.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Use Mac Microphone",isOn:$model.microphoneEnabled).disabled(model.hasSession || model.isBusy)
        if model.microphoneEnabled {
            Toggle("Mute Microphone",isOn:$model.microphoneMuted)
            Text(model.microphoneStatus).font(.caption).foregroundStyle(.secondary)
        }
        Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
        if model.canRetryAudio { Button("Retry Audio") { model.retryAudioOutput() } }
    }
}
