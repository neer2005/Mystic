import SwiftUI
import AppKit
import Combine
import GameController
import MysticStream
import MysticCore
import MysticKit

public struct StreamingView: View {
    @State private var showingHostSession=false
    @State private var showingHealth=false
    @State private var window: NSWindow?
    @State private var controllerNotice: ControllerNotice?
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Bindable private var model: ConnectionModel
    public init(model: ConnectionModel) { self.model = model }
    private var streaming: Bool { model.phase == .streaming }
    /// Input state is the most useful line while streaming: it names the release chord.
    private var subtitle: String {
        if streaming,let capture=model.inputCapture { return capture.status }
        return model.status
    }
    private func showHostSession() { showingHostSession=true;model.inputCapture?.release() }
    private func showHealth() { showingHealth=true;model.inputCapture?.release() }
    private var controlling: Bool { (model.inputCapture?.mode ?? .released) != .released }
    private func updateDock() { StreamDock.update(window:window,controlling:controlling) }
    /// The HIG asks games to say when a controller comes or goes; mid-game, input that stops
    /// for no visible reason is the alternative. Only pads the stream sends count.
    private func controllerChanged(_ note: Notification) {
        guard streaming,model.inputPreferences.controllers,let controller=note.object as? GCController,
              controller.extendedGamepad != nil else { return }
        let notice=ControllerNotice(name:controller.vendorName ?? "Controller",connected:note.name == .GCControllerDidConnect)
        withAnimation(.easeOut(duration:0.2)) { controllerNotice=notice }
        Task { @MainActor in
            try? await Task.sleep(for:.seconds(3))
            if controllerNotice == notice { withAnimation(.easeIn(duration:0.3)) { controllerNotice=nil } }
        }
    }
    @ToolbarContentBuilder private var toolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id:"capture") {
            Button("Capture Mouse",systemImage:"computermouse") { model.inputCapture?.captureMouse() }
                .disabled(model.inputCapture?.available != true)
                .help("Send relative mouse movement for games. Control–Option–Shift–Escape releases input.")
        }
        ToolbarItem(id:"sound") {
            Button(model.muted ? "Unmute Sound" : "Mute Sound",systemImage:model.muted ? "speaker.slash" : "speaker.wave.2") { model.muted.toggle() }
                .help(model.audioStatus)
        }
        ToolbarItem(id:"microphone") {
            Button(model.microphoneMuted ? "Unmute Microphone" : "Mute Microphone",systemImage:model.microphoneMuted ? "mic.slash" : "mic") { model.microphoneMuted.toggle() }
                .disabled(!model.microphoneEnabled || !streaming)
                .help(model.microphoneEnabled ? model.microphoneStatus : "Turn on Use Mac Microphone in Settings to send your microphone.")
        }
        ToolbarItem(id:"clipboard") {
            Menu {
                Button("Send Clipboard Text to Host") { model.sendClipboardToHost() }.disabled(!model.canSendClipboard)
                Button("Copy Host Clipboard Text to Mac") { model.copyHostClipboard() }.disabled(!model.canReadClipboard)
                if model.offersClipboardImages {
                    Button("Send Clipboard Image to Host") { model.sendClipboardImageToHost() }.disabled(!model.canMoveClipboardImage)
                    Button("Copy Host Clipboard Image to Mac") { model.copyHostClipboardImage() }.disabled(!model.canMoveClipboardImage)
                }
                Divider()
                Text(model.clipboardStatus)
            } label: { Label("Clipboard",systemImage:"doc.on.clipboard") }
            .help(model.clipboardStatus)
            .disabled(!streaming)
        }.defaultCustomization(.hidden)
        ToolbarItem(id:"shortcuts") {
            Menu { ShortcutMenuItems(model:model) } label: { Label("Send Shortcut",systemImage:"command") }
                .help("Send a saved key shortcut to the host")
                .disabled(!streaming)
        }.defaultCustomization(.hidden)
        ToolbarItem(id:"health") {
            Button("Stream Health",systemImage:"stethoscope",action:showHealth)
                .disabled(!streaming)
                .help("Why did my stream stutter?")
        }.defaultCustomization(.hidden)
        ToolbarItem(id:"latency") {
            Toggle(isOn:$model.showLatencyHUD) { Label("Performance Overlay",systemImage:"chart.bar.xaxis") }
                .help("Show the stream's frame rate, network delay and loss. Settings → General chooses how much.")
        }.defaultCustomization(.hidden)
        ToolbarItem(id:"session") {
            Button("Host Controls",systemImage:"slider.horizontal.3",action:showHostSession)
                .disabled(!streaming)
                .help("Session, graphics, stream rates and sound")
        }
        ToolbarItem(id:"disconnect") {
            Button("Disconnect",systemImage:"xmark.circle") { model.leave() }
                .disabled(!model.canDisconnect)
                .help("End the stream. The game keeps running on the host.")
        }
    }
    public var body: some View {
        VStack(spacing: 0) {
            if let presenter = model.presenter {
                VideoSurface(presenter: presenter,capture:model.inputCapture)
                    .overlay(alignment:.topLeading) {
                        if model.showLatencyHUD {
                            PerformanceOverlay(mode:model.overlayMode,stream:model.overlayStreamLine,
                                               measures:OverlayMeasures(snapshot:model.videoTelemetry,network:model.health.measures),
                                               hardware:model.hostHardware.reading) {
                                LatencyHUD(snapshot:model.videoTelemetry,mode:presenter.pacingMode,output:presenter.videoOutput,bitrate:model.rates.status,network:model.health.measures)
                            }
                            .padding(12).allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                    // Drawn over the picture, so macOS composites while it shows: three seconds,
                        // only when a pad comes or goes, the same trade as the performance overlay.
                        .overlay(alignment:.top) {
                            if let controllerNotice {
                                Label(controllerNotice.text,systemImage:controllerNotice.connected ? "gamecontroller.fill" : "gamecontroller")
                                    .padding(.horizontal,14).padding(.vertical,8)
                                    .background(.regularMaterial,in:Capsule())
                                    .padding(16).allowsHitTesting(false)
                                    .transition(.move(edge:.top).combined(with:.opacity))
                                    .accessibilityAddTraits(.updatesFrequently)
                            }
                        }
                    .overlay(alignment:.bottom) {
                        if model.latencyTestRunning {
                            Label("Measuring… show a still desktop with the mouse pointer and don't touch anything for a few seconds.",systemImage:"timer")
                                .padding(.horizontal,14).padding(.vertical,8)
                                .background(.regularMaterial,in:Capsule())
                                .padding(16).allowsHitTesting(false)
                        }
                    }
            }
            else {
                ZStack {
                    Color.black
                    if model.isBusy { ProgressView(model.status).tint(.white).foregroundStyle(.white) }
                    else if let error=model.errorMessage { streamEnded(error) }
                    else { Text("Not connected").foregroundStyle(.white) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle(model.streamingAppName ?? "Stream")
        .navigationSubtitle(subtitle)
        .sheet(isPresented:$showingHostSession) { HostSessionView(model:model) }
        .sheet(isPresented:$showingHealth) { StreamHealthView(model:model) }
        .alert("Measure Input Latency",isPresented:Binding(get:{ model.latencyTestResult != nil },set:{ if !$0 { model.latencyTestResult=nil } })) {
            Button("OK",role:.cancel) {}
        } message: { Text(model.latencyTestResult ?? "") }
        .focusedSceneValue(\.hostSessionAction,streaming ? { showHostSession() } : nil)
        .focusedSceneValue(\.streamHealthAction,streaming ? { showHealth() } : nil)
        // Frequent controls only; everything else is in the Stream menu or Customize Toolbar.
        .toolbar(id:"stream") { toolbarItems }
        .toolbar {
            // Appears only while the output is lost, so the problem is visible without a menu.
            if model.canRetryAudio {
                ToolbarItem { Button("Retry Audio",systemImage:"speaker.badge.exclamationmark") { model.retryAudioOutput() }.help(model.audioStatus) }
            }
        }
        .windowToolbarFullScreenVisibility(.onHover)
        .background(WindowReader { window=$0
            // The notch mode is opt-in and System-only, as macOS composites it (see `StreamVideoSettings.limited(to:)`).
            // Both settings are locked while a stream runs, so they match the stream in this window.
            if let window=$0 { NotchFullScreen.install(on:window) { [model] in model.videoOutput.coversNotch ? model.presenter?.videoSize ?? .zero : .zero } }
        })
        .fullScreenCommandTarget()
        .onChange(of:controlling,initial:true) { updateDock() }
        .onReceive(StreamWindowEvents.windowChanges) { note in if let window,note.object as? NSWindow === window { updateDock() } }
        .onReceive(StreamWindowEvents.controllerChanges,perform:controllerChanged)
        // When the stream ends, a full-screen window must not be left showing an empty Space.
        // A deliberate end closes the window; one that ended with an error stays to show it.
        .onChange(of:model.phase) { old,new in
            guard old != new,new == .idle || new == .failed else { return }
            if model.errorMessage == nil { dismissWindow(id:"stream") }
            else if let window,window.isStreamFullScreen { window.toggleFullScreen(nil) }
        }
        // Entering or leaving the notch-covering full screen briefly remounts the view.
        .onDisappear {
            guard !NotchFullScreen.isRestyling(window) else { return }
            StreamDock.update(window:nil,controlling:false)
            if model.hasSession { model.leave() }
        }
    }
    /// A stream that ended with an error keeps its window, so it says what happened and offers
    /// the way on, as the library's empty states do, instead of leaving text on black.
    private func streamEnded(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Stream Ended",systemImage:"exclamationmark.triangle")
        } description: {
            Text(error).textSelection(.enabled)
        } actions: {
            HStack {
                Button("Close") { dismissWindow(id:"stream") }.keyboardShortcut(.cancelAction)
                if model.canPlay,let app=model.library.selected {
                    Button("Start \(app.name) Again") {
                        Task {
                            await model.requestGameAction(startSelected:true)
                            // Quitting another game first is confirmed in the library window.
                            if model.pendingGameAction != nil { openWindow(id:"library") }
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large)
        }
        .environment(\.colorScheme,.dark)
    }
}

/// Built once: the stream view re-renders several times a second while the overlay updates,
/// and a publisher made in `body` would have `onReceive` subscribe again on each render,
/// main-thread work the stream doesn't need beside it.
@MainActor
private enum StreamWindowEvents {
    /// Full-screen and key changes of any window; the view keeps those of its own.
    static let windowChanges: AnyPublisher<Notification,Never>={
        let center=NotificationCenter.default
        return Publishers.MergeMany([NSWindow.didEnterFullScreenNotification,NSWindow.didExitFullScreenNotification,
                                     NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,
                                     NotchFullScreen.didChangeNotification].map { center.publisher(for:$0) })
            .eraseToAnyPublisher()
    }()
    static let controllerChanges: AnyPublisher<Notification,Never>={
        let center=NotificationCenter.default
        return center.publisher(for:.GCControllerDidConnect).merge(with:center.publisher(for:.GCControllerDidDisconnect))
            .receive(on:DispatchQueue.main).eraseToAnyPublisher()
    }()
}

/// A controller arriving or leaving during a stream.
private struct ControllerNotice: Equatable {
    let id=UUID()
    let name: String
    let connected: Bool
    var text: String { "\(name) \(connected ? "connected" : "disconnected")" }
}

private struct VideoSurface: NSViewRepresentable {
    let presenter: DisplayLayerPresenter
    let capture: StreamInputCapture?
    func makeNSView(context: Context) -> RemoteVideoView { RemoteVideoView(presenter:presenter,capture:capture) }
    func updateNSView(_ view: RemoteVideoView,context: Context) { view.install(presenter,capture:capture) }
    static func dismantleNSView(_ view: RemoteVideoView,coordinator: ()) { view.disconnectInput() }
}

/// Read-only overlay; pointer and keyboard events continue to the streaming view.
private struct LatencyHUD: View {
    let snapshot: VideoTelemetrySnapshot?
    let mode: FramePacingMode
    let output: VideoOutputState
    let bitrate: String
    let network: NetworkMeasures?
    private func milliseconds(_ value: Int64) -> String { String(format:"%.2f",Double(value)/1000) }
    private func rate(_ value: Double?) -> String { value.map { String(format:"%.1f",$0) } ?? "—" }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Video latency · \(mode.label)").font(.headline)
            Text("Decoded \(rate(snapshot?.decodedFPS)) fps · Enqueued \(rate(snapshot?.enqueuedFPS)) fps")
            Text(bitrate)
            if let network { NetworkFigures(measures:network) }
            Text("Source \(output.transfer) · \(output.colorPrimaries) · \(output.outputDescription)")
            if output.isHDR {
                Text("HDR metadata: mastering \(output.hasMasteringMetadata ? "present" : "absent") · light levels \(output.hasContentLightMetadata ? "present" : "absent")")
            }
            if let screen=output.screenName {
                Text("\(screen) · EDR headroom \(rate(output.currentHeadroom))× current / \(rate(output.potentialHeadroom))× potential")
            }
            Grid(alignment:.leading,horizontalSpacing:14,verticalSpacing:4) {
                GridRow {
                    Text("Rolling 600 frames")
                    Text("p50 ms");Text("p95 ms")
                }.foregroundStyle(.secondary)
                ForEach(VideoTimingStage.allCases,id: \.self) { stage in
                    GridRow {
                        Text(stage.label)
                        if let timing=snapshot?.timings[stage] {
                            Text(milliseconds(timing.p50Micros))
                            Text(milliseconds(timing.p95Micros))
                        } else { Text("—");Text("—") }
                    }
                }
            }
            if let snapshot {
                Text("Submitted \(snapshot.submitted) · Decoded \(snapshot.decoded) · Enqueued \(snapshot.enqueued)")
                let presentation=snapshot.presentation
                Text("Presenter queue \(presentation.queueDepth) · Peak \(presentation.peakQueueDepth) · Late \(presentation.lateFrames)\(presentation.holdMicros.map { " · Held \(String(format:"%.1f",Double($0)/1000)) ms" } ?? "")")
                if let shown=presentation.cadence.summary {
                    Text("Shown every \(String(format:"%.1f / %.1f / %.1f",Double(shown.p50)/1000,Double(shown.p95)/1000,Double(shown.p99)/1000)) ms (p50/p95/p99) · Uneven \(Int((presentation.cadence.unevenShare ?? 0)*100))%")
                }
                if let lead=presentation.phaseLeadMicros { Text("Phase lock lead \(String(format:"%.1f",Double(lead)/1000)) ms") }
                if let shown=presentation.cadence.pcToShownSummary,let received=presentation.cadence.pcToReceivedSummary {
                    Text("PC to screen \(String(format:"%.1f / %.1f",Double(shown.p50)/1000,Double(shown.p95)/1000)) ms · to here \(String(format:"%.1f",Double(received.p50)/1000)) ms")
                }
                Text("Presenter drops \(presentation.droppedFrames) · Superseded \(presentation.drops[.superseded,default:0]) · Late \(presentation.drops[.late,default:0])")
                Text("Order/time \(presentation.drops[.outOfOrder,default:0] + presentation.drops[.invalidTimestamp,default:0]) · Reset discards \(presentation.drops[.reset,default:0]) · Enqueue errors \(presentation.drops[.enqueueFailure,default:0])")
                Text("Timeline resets \(presentation.resynchronizations) · Renderer drops \(presentation.rendererDroppedFrames.map(String.init) ?? "—") · Corrupt \(presentation.rendererCorruptedFrames.map(String.init) ?? "—")")
            } else { Text("Waiting for video measurements…") }
            Text("Enqueue ends at renderer acceptance.\nNetwork transit and screen latency unavailable.")
                .foregroundStyle(.secondary)
        }
    }
}
