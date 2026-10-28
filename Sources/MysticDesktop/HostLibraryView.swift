import SwiftUI
import MysticCore
import MysticKit
import MysticStream

public struct HostLibraryView: View {
    @Bindable private var model: ConnectionModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    public init(model: ConnectionModel) { self.model=model }
    public var body: some View {
        NavigationSplitView {
            HostSidebar(model:model)
                .navigationTitle("Mystic")
                .navigationSplitViewColumnWidth(min:220,ideal:250,max:320)
        } content: {
            library
                .navigationTitle(model.host?.name ?? "Library")
                .navigationSplitViewColumnWidth(min:300,ideal:450)
        } detail: {
            streamDetails
                .navigationTitle("Stream Details")
                .navigationSplitViewColumnWidth(min:300,ideal:340,max:420)
        }
        .frame(minWidth:1000,minHeight:580)
        .focusedSceneValue(\.librarySearchAction, { searchFocused=true })
        .task { model.libraryAppeared();await model.prepare() }
        .onDisappear { model.libraryDisappeared() }
        .onChange(of:model.settings.value) { model.applyLiveSettings() }
    }
    @ViewBuilder private var library: some View {
        VStack(spacing:0) {
            if model.apps.isEmpty {
                ContentUnavailableView(model.isBusy ? "Connecting to Host" : "Choose a Host",systemImage:"desktopcomputer",
                    description:Text(model.isBusy ? model.status : "Select a saved or nearby host, or add its address in the sidebar."))
            } else if model.filteredApps.isEmpty {
                ContentUnavailableView.search(text:model.libraryQuery)
            } else if model.settings.value.libraryLayout == "list" {
                List(model.filteredApps,selection:$model.selectedAppID) { app in
                    Label { HStack { Text(app.name);Spacer();if app.hdrSupported { Text("HDR").font(.caption).foregroundStyle(.secondary) } } }
                        icon: { Image(systemName:app.name == "Desktop" ? "desktopcomputer" : "gamecontroller") }
                        .tag(app.id)
                        .contextMenu { Button("Start Stream",systemImage:"play.fill") { model.selectedAppID=app.id;startStream() }.disabled(!model.canPlay) }
                }.listStyle(.inset)
            } else {
                AppGrid(apps:model.filteredApps,selection:$model.selectedAppID,start:startStream)
            }
            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(2)
                Spacer()
                if !model.apps.isEmpty { Text("\(model.filteredApps.count) \(model.filteredApps.count == 1 ? "app" : "apps")") }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .disabled(model.hasSession || model.isBusy)
        .searchable(text:$model.libraryQuery,prompt:"Search Apps")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem {
                Picker("Library View",selection:setting(\.libraryLayout)) {
                    Label("Grid",systemImage:"square.grid.2x2").tag("grid")
                    Label("List",systemImage:"list.bullet").tag("list")
                }.pickerStyle(.segmented).help("Choose Grid or List")
            }
            ToolbarItem {
                Menu("Filter and Sort",systemImage:"line.3.horizontal.decrease") {
                    Toggle("HDR Apps Only",isOn:$model.libraryHDROnly)
                    Picker("Sort Apps",selection:setting(\.librarySort)) {
                        Text("Name").tag("name");Text("Host Order").tag("host")
                    }
                }.disabled(model.hasSession || model.isBusy)
            }
        }
    }
    private func setting<T>(_ key: WritableKeyPath<StreamPreferences,T>) -> Binding<T> {
        Binding(get:{ model.settings.value[keyPath:key] },set:{ value in model.settings.update { $0[keyPath:key]=value } })
    }
    private func startStream() { model.play();if model.hasSession { openWindow(id:"stream") } }
    private var streamDetails: some View {
        Form {
            if let error=model.errorMessage { Section { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) } }
            if let app=model.selectedApp {
                Section {
                    Label(app.name,systemImage:app.name == "Desktop" ? "desktopcomputer" : "gamecontroller").font(.title2)
                    if app.hdrSupported { Label("HDR available on host",systemImage:"sparkles").foregroundStyle(.secondary) }
                    Button("Start Stream",systemImage:"play.fill",action:startStream)
                        .buttonStyle(.borderedProminent).disabled(!model.canPlay)
                        .keyboardShortcut(.return,modifiers:[])
                }
                Section("Video") { VideoPreferencesView(model:model) }
                Section("Audio") { AudioPreferencesView(model:model) }
                Section { Text("Changes are saved as defaults for future streams. Video and channel layout are fixed while streaming.").font(.caption).foregroundStyle(.secondary) }
            } else { Section { Text("Select an app to see stream options.").foregroundStyle(.secondary) } }
            Section("Controls") {
                Text("Click the video to control the host. Capture Mouse enables relative movement for games.")
                LabeledContent("Release Input",value:"⌃⌥⇧Esc")
                Text("Connected controllers follow input capture.").foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                DisclosureGroup("Hardware Decoders") {
                    if let capabilities=model.capabilities {
                        ForEach(VideoFormat.allCases,id:\.rawValue) { format in
                            LabeledContent(format.displayName) {
                                Image(systemName:capabilities.supportedFormats & format.rawValue != 0 ? "checkmark.circle" : "minus.circle")
                                    .accessibilityLabel(capabilities.exclusionReasons[format.rawValue] ?? "Hardware verified")
                                    .help(capabilities.exclusionReasons[format.rawValue] ?? "Hardware verified")
                            }
                        }
                    } else { ProgressView("Checking hardware…") }
                }
                if !model.diagnostics.isEmpty {
                    DisclosureGroup("Session Log") {
                        Text(model.diagnostics.joined(separator:"\n")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

private struct HostSidebar: View {
    @Bindable var model: ConnectionModel
    @State private var addingHost=false
    private var locked: Bool { model.hasSession || model.isBusy }
    var body: some View {
        List(selection:Binding(get:{model.selectedHostEndpointID},set:{model.selectHost($0)})) {
            Section("Saved Hosts") {
                ForEach(model.savedHosts.hosts) { host in
                    hostLabel(host.name,endpoint:host.endpoint).tag(host.id)
                        .contextMenu {
                            Button("Connect",systemImage:"network") { model.connect(to:host.endpoint) }.disabled(locked)
                            Button("Remove from Saved Hosts",systemImage:"minus.circle") { model.savedHosts.remove(host.endpoint) }.disabled(locked)
                        }
                        .help("\(host.endpoint.id). Removing from Saved Hosts keeps its Keychain pairing.")
                        .disabled(locked)
                }
            }
            Section("Nearby Hosts") {
                ForEach(model.discovery.hosts.filter { nearby in !model.savedHosts.hosts.contains { $0.id == nearby.id } }) { host in
                    hostLabel(host.name,endpoint:host.endpoint).tag(host.id).disabled(locked)
                }
                Text(model.discovery.status).font(.caption).foregroundStyle(.secondary)
                Button("Refresh Discovery",systemImage:"arrow.clockwise") { model.discovery.refresh() }
                    .disabled(!model.settings.value.discoveryEnabled)
            }
            Section {
                DisclosureGroup("Add Host",isExpanded:$addingHost) {
                    TextField("Address",text:$model.address,prompt:Text("192.168.1.100"))
                        .textFieldStyle(.roundedBorder).onSubmit { model.connect() }
                    TextField("HTTP Port",text:$model.port).textFieldStyle(.roundedBorder)
                    Button("Connect",systemImage:"network") { model.connect() }
                }.disabled(locked)
            }
            if let host=model.host {
                Section(host.name) {
                    Label(host.paired ? "Paired" : "Pairing Required",systemImage:host.paired ? "lock.shield" : "lock.open")
                    if !host.paired && model.phase == .ready { Button("Pair with Host") { model.pair() } }
                    if let pin=model.pairingPIN {
                        Text(pin).font(.largeTitle.monospacedDigit()).textSelection(.enabled)
                        Text("Enter this PIN on your host.").font(.caption)
                    }
                    Button("Disconnect",systemImage:"xmark.circle") { model.disconnect() }.disabled(model.phase == .disconnecting)
                }
            } else if model.isBusy {
                Button("Cancel Connection") { model.disconnect() }
            }
            if let error=model.savedHosts.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .listStyle(.sidebar)
        .onAppear { addingHost=model.savedHosts.hosts.isEmpty }
        .toolbar { ToolbarItem { Button("Add Host",systemImage:"plus") { addingHost=true }.disabled(locked) } }
    }
    private func hostLabel(_ name: String,endpoint: HostEndpoint) -> some View {
        Label {
            VStack(alignment:.leading,spacing:2) { Text(name);Text(endpoint.id).font(.caption).foregroundStyle(.secondary) }
        } icon: { Image(systemName:"desktopcomputer") }
    }
}

private struct AppGrid: View {
    let apps: [HostApp]
    @Binding var selection: Int32?
    let start: () -> Void
    @State private var width: CGFloat=400
    private var columns: Int { max(1,Int((width+16)/156)) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:140),spacing:16)],spacing:20) {
                    ForEach(apps) { app in
                        Button { selection=app.id } label: {
                            VStack(spacing:8) {
                                RoundedRectangle(cornerRadius:8).fill(.quaternary)
                                    .aspectRatio(4/3,contentMode:.fit)
                                    .overlay { Image(systemName:app.name == "Desktop" ? "desktopcomputer" : "gamecontroller").font(.largeTitle).foregroundStyle(.tint) }
                                Text(app.name).font(.callout).lineLimit(2).frame(maxWidth:.infinity)
                            }.padding(8)
                                .background(selection == app.id ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:10))
                                .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(selection == app.id ? Color.accentColor : Color.clear,lineWidth:2) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(app.id)
                            .accessibilityLabel(app.name).accessibilityAddTraits(selection == app.id ? .isSelected : [])
                            .contextMenu { Button("Start Stream",systemImage:"play.fill") { selection=app.id;start() } }
                    }
                }.padding(16)
            }
            .onGeometryChange(for:CGFloat.self) { $0.size.width-32 } action: { width=$0 }
            .focusable()
            .onMoveCommand { direction in
                guard !apps.isEmpty else { return }
                let current=apps.firstIndex { $0.id == selection } ?? 0
                let delta: Int
                switch direction { case .left:delta = -1;case .right:delta=1;case .up:delta = -columns;case .down:delta=columns;default:return }
                selection=apps[min(apps.count-1,max(0,current+delta))].id
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }
}

extension VideoFormat {
    var displayName: String {
        let codec=isH264 ? "H.264" : (isAV1 ? "AV1" : "HEVC")
        return "\(codec) · \(tenBit ? "10" : "8")-bit · \(chroma444 ? "4:4:4" : "4:2:0")"
    }
}
