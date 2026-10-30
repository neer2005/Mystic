import SwiftUI
import AppKit
import MysticStream
import MysticCore

public struct StreamingView: View {
    @State private var streamWindow: NSWindow?
    @Bindable private var model: ConnectionModel
    public init(model: ConnectionModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            if let presenter = model.presenter {
                VideoSurface(presenter: presenter,capture:model.inputCapture)
                    .overlay(alignment:.topLeading) {
                        if model.showLatencyHUD {
                            LatencyHUD(snapshot:model.videoTelemetry,mode:presenter.pacingMode)
                                .padding(12).allowsHitTesting(false)
                        }
                    }
            }
            else {
                ZStack {
                    Color.black
                    if model.isBusy { ProgressView(model.status).tint(.white).foregroundStyle(.white) }
                    else { Text(model.errorMessage ?? model.status).foregroundStyle(.white).padding() }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .toolbar {
            ToolbarItem { Text(model.status).font(.caption).lineLimit(1) }
            if model.adaptiveBitrate {
                ToolbarItem { Text(model.bitrateStatus).font(.caption).lineLimit(1) }
            }
            if let capture = model.inputCapture {
                ToolbarItem { Text(capture.status).font(.caption).help("Control–Option–Shift–Escape releases input. Switching apps also releases it.") }
                ToolbarItem { Button("Control Desktop",systemImage:"cursorarrow") { capture.controlDesktop() }.disabled(!capture.available) }
                ToolbarItem { Button("Capture Mouse",systemImage:"computermouse") { capture.captureMouse() }.disabled(!capture.available) }
                ToolbarItem { Button("Release Input",systemImage:"escape") { capture.release() }.disabled(capture.mode == .released) }
            }
            ToolbarItem {
                Toggle(isOn:$model.showLatencyHUD) { Label("Latency HUD",systemImage:"chart.bar.xaxis") }
                    .help("Show measured video timings and renderer enqueue rate")
            }
            #if DEBUG
            ToolbarItem {
                Button("Test Video Recovery",systemImage:"arrow.clockwise") { model.simulateVideoLoss() }
                    .disabled(model.phase != .streaming)
                    .help("Development test: discard one compressed frame and request a new keyframe.")
            }
            #endif
            ToolbarItem {
                Menu {
                    Button("Send Text to Host") { model.sendClipboardToHost() }.disabled(!model.canSendClipboard)
                    Button("Copy Host Text to Mac") { model.copyHostClipboard() }.disabled(!model.canReadClipboard)
                    Divider()
                    Text(model.clipboardStatus)
                } label: { Label("Clipboard",systemImage:"doc.on.clipboard") }
                .help(model.clipboardStatus)
                .disabled(model.phase != .streaming)
            }
            ToolbarItem { Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { streamWindow?.toggleFullScreen(nil) } }
            ToolbarItem { Button(model.muted ? "Unmute" : "Mute", systemImage: model.muted ? "speaker.slash" : "speaker.wave.2") { model.muted.toggle() } }
            if model.microphoneEnabled {
                ToolbarItem {
                    Button(model.microphoneMuted ? "Unmute Microphone" : "Mute Microphone",systemImage:model.microphoneMuted ? "mic.slash" : "mic") { model.microphoneMuted.toggle() }
                        .help(model.microphoneStatus)
                }
                ToolbarItem { Text(model.microphoneStatus).font(.caption).lineLimit(1) }
            }
            ToolbarItem { Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() } }
        }
        .windowToolbarFullScreenVisibility(.onHover)
        .background(WindowReader { streamWindow = $0 })
        .onDisappear { if model.hasSession { model.disconnect() } }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let presenter: DisplayLayerPresenter
    let capture: StreamInputCapture?
    func makeNSView(context: Context) -> RemoteVideoView { RemoteVideoView(presenter:presenter,capture:capture) }
    func updateNSView(_ view: RemoteVideoView,context: Context) { view.install(presenter,capture:capture) }
    static func dismantleNSView(_ view: RemoteVideoView,coordinator: ()) { view.disconnectInput() }
}

private struct WindowReader: NSViewRepresentable {
    let receive: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(receive: receive) }
    func updateNSView(_ view: WindowProbe, context: Context) {}
}
private final class WindowProbe: NSView {
    let receive: @MainActor (NSWindow?) -> Void
    init(receive: @escaping @MainActor (NSWindow?) -> Void) { self.receive = receive; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in guard let self else { return }; receive(window) }
    }
}

/// Read-only overlay; pointer and keyboard events continue to the streaming view.
private struct LatencyHUD: View {
    let snapshot: VideoTelemetrySnapshot?
    let mode: FramePacingMode
    private func milliseconds(_ value: Int64) -> String { String(format:"%.2f",Double(value)/1000) }
    private func rate(_ value: Double?) -> String { value.map { String(format:"%.1f",$0) } ?? "—" }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Video latency · \(mode.label)").font(.headline)
            Text("Decoded \(rate(snapshot?.decodedFPS)) fps · Enqueued \(rate(snapshot?.enqueuedFPS)) fps")
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
                Text("Presenter queue \(presentation.queueDepth)/2 · Peak \(presentation.peakQueueDepth) · Late \(presentation.lateFrames)")
                Text("Presenter drops \(presentation.droppedFrames) · Superseded \(presentation.drops[.superseded,default:0]) · Late \(presentation.drops[.late,default:0])")
                Text("Order/time \(presentation.drops[.outOfOrder,default:0] + presentation.drops[.invalidTimestamp,default:0]) · Reset discards \(presentation.drops[.reset,default:0]) · Enqueue errors \(presentation.drops[.enqueueFailure,default:0])")
                Text("Timeline resets \(presentation.resynchronizations) · Renderer drops \(presentation.rendererDroppedFrames.map(String.init) ?? "—") · Corrupt \(presentation.rendererCorruptedFrames.map(String.init) ?? "—")")
            } else { Text("Waiting for video measurements…") }
            Text("Enqueue ends at renderer acceptance.\nNetwork transit and screen latency unavailable.")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:10))
        .accessibilityElement(children:.combine)
    }
}
