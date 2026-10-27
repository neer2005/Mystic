import SwiftUI
import AppKit
import MysticStream

public struct HostLibraryView: View {
    @Bindable private var model: ConnectionModel
    @Environment(\.openWindow) private var openWindow
    public init(model: ConnectionModel) { self.model = model }
    public var body: some View {
        NavigationSplitView {
            Form {
                Section("Host") {
                    TextField("LAN address", text: $model.address, prompt: Text("192.168.1.100"))
                        .onSubmit { model.connect() }.disabled(model.hasSession || model.isBusy)
                    TextField("HTTP port", text: $model.port).disabled(model.hasSession || model.isBusy)
                    Button("Connect", systemImage: "network") { model.connect() }
                        .disabled(model.isBusy || model.hasSession)
                    if model.host != nil || model.isBusy || model.hasSession {
                        Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() }
                            .disabled(model.phase == .disconnecting)
                    }
                }
                if let host = model.host {
                    Section(host.name) {
                        Label(host.paired ? "Paired" : "Pairing required", systemImage: host.paired ? "lock.shield" : "lock.open")
                        if !host.paired && model.phase == .ready {
                            Button("Pair with Host") { model.pair() }
                        }
                    }
                }
                if let pin = model.pairingPIN {
                    Section("Pairing PIN") {
                        Text(pin).font(.largeTitle.monospacedDigit()).textSelection(.enabled)
                        Text("Enter this PIN in Sunshine/Apollo’s PIN page on your host.").font(.callout)
                        Button("Cancel Pairing") { model.disconnect() }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Mystic")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.status).foregroundStyle(.secondary)
                    Spacer()
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                if model.apps.isEmpty {
                    ContentUnavailableView("Connect to Your Host", systemImage: "desktopcomputer",
                        description: Text("Pair to browse your host’s applications and start a video stream."))
                } else {
                    List(model.apps, selection: $model.selectedAppID) { app in
                        HStack {
                            Image(systemName: "gamecontroller")
                            Text(app.name)
                            Spacer()
                            if app.hdrSupported { Text("HDR").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(app.id)
                    }
                    .disabled(model.hasSession || model.isBusy)
                    HStack {
                        Picker("Resolution", selection: $model.resolution) {
                            Text("1280 × 720").tag("1280x720")
                            Text("1920 × 1080").tag("1920x1080")
                            Text("2560 × 1440").tag("2560x1440")
                            Text("3840 × 2160").tag("3840x2160")
                        }
                        Picker("FPS", selection: $model.fps) {
                            Text("60").tag(UInt32(60)); Text("120").tag(UInt32(120))
                        }.frame(width: 110)
                    }
                    .disabled(model.hasSession || model.isBusy)
                    HStack {
                        Picker("Codec", selection: $model.codec) {
                            Text("Automatic").tag("auto"); Text("H.264").tag("h264")
                            Text("HEVC").tag("hevc"); Text("AV1").tag("av1")
                        }
                        Stepper("\(model.bitrateMbps) Mbps", value: $model.bitrateMbps, in: 5...150, step: 5)
                        Toggle("HDR", isOn: $model.hdr).disabled(model.selectedApp?.hdrSupported != true)
                    }
                    .disabled(model.hasSession || model.isBusy)
                    HStack {
                        Picker("Host audio", selection: $model.audioLayout) {
                            Text("Stereo").tag("stereo")
                            Text("5.1 → Stereo").tag("5.1")
                            Text("7.1 → Stereo").tag("7.1")
                        }.disabled(model.hasSession || model.isBusy)
                        Toggle("Mute", isOn: $model.muted)
                        Slider(value: $model.volume, in: 0...1) { Text("Volume") }.frame(maxWidth: 160)
                    }
                    Text(model.audioStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Start Stream", systemImage: "play.fill") {
                        model.play()
                        if model.hasSession { openWindow(id: "stream") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPlay)
                    Text("Audio plays on this Mac. Remote keyboard, mouse, and controller input are not connected yet.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Decoder capabilities") {
                    if let capabilities = model.capabilities {
                        ForEach(VideoFormat.allCases, id: \.rawValue) { format in
                            HStack {
                                Text(String(describing: format))
                                Spacer()
                                Text(capabilities.exclusionReasons[format.rawValue] ?? "Hardware verified")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    } else { ProgressView("Checking hardware decoders…") }
                }
                if !model.diagnostics.isEmpty {
                    DisclosureGroup("Video diagnostics") {
                        ScrollView { Text(model.diagnostics.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
                            .frame(maxHeight: 120)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 620, minHeight: 480)
            .task { await model.prepare() }
        }
    }
}

public struct StreamingView: View {
    @State private var streamWindow: NSWindow?
    @Bindable private var model: ConnectionModel
    public init(model: ConnectionModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            if let presenter = model.presenter { VideoSurface(presenter: presenter) }
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
            ToolbarItem { Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { streamWindow?.toggleFullScreen(nil) } }
            ToolbarItem { Button(model.muted ? "Unmute" : "Mute", systemImage: model.muted ? "speaker.slash" : "speaker.wave.2") { model.muted.toggle() } }
            ToolbarItem { Button("Disconnect", systemImage: "xmark.circle") { model.disconnect() } }
        }
        .background(WindowReader { streamWindow = $0 })
        .onDisappear { if model.hasSession { model.disconnect() } }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let presenter: DisplayLayerPresenter
    func makeNSView(context: Context) -> SurfaceView { SurfaceView(presenter: presenter) }
    func updateNSView(_ view: SurfaceView, context: Context) {
        if view.presenter !== presenter { view.install(presenter) }
    }
}
private final class SurfaceView: NSView {
    var presenter: DisplayLayerPresenter
    init(presenter: DisplayLayerPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(presenter.layer)
    }
    required init?(coder: NSCoder) { nil }
    func install(_ presenter: DisplayLayerPresenter) {
        self.presenter.layer.removeFromSuperlayer()
        self.presenter = presenter; layer?.addSublayer(presenter.layer); needsLayout = true
    }
    override func layout() { super.layout(); presenter.layer.frame = bounds }
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
