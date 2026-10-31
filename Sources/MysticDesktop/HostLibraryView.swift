import SwiftUI
import AppKit
import MysticCore
import MysticKit
import MysticStream

public struct HostLibraryView: View {
    @Bindable private var model: ConnectionModel
    @State private var showingHostSession=false
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    public init(model: ConnectionModel) { self.model=model }
    public var body: some View {
        NavigationSplitView {
            HostSidebar(model:model)
                .navigationTitle("Mystic")
                .navigationSplitViewColumnWidth(min:220,ideal:250,max:320)
        } content: {
            Group {
                if model.showingHome { HomeLibraryContent(model:model) }
                else { library }
            }
                .navigationTitle(model.showingHome ? "Home" : (model.host?.name ?? "Library"))
                .navigationSplitViewColumnWidth(min:300,ideal:450)
        } detail: {
            Group {
                if model.showingHome { HomeGameDetails(model:model) }
                else { streamDetails }
            }
                .navigationTitle(model.showingHome ? "Game Details" : "Stream Details")
                .navigationSplitViewColumnWidth(min:300,ideal:340,max:420)
        }
        .sheet(item:Binding(get:{model.pendingGameAction},set:{if $0 == nil { model.cancelGameAction() }})) { action in
            VStack(alignment:.leading,spacing:16) {
                Text(action.title).font(.title2)
                Text("Quit \(action.runningName) on \(action.running.name)? Unsaved progress may be lost.")
                if let target=action.target { Text("After the host confirms it has quit, Mystic will start \(target.name) with its saved stream settings.").foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel",role:.cancel) { model.cancelGameAction() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action.title,role:.destructive) {
                        Task { await model.confirmGameAction(action);if model.hasSession { openWindow(id:"stream") } }
                    }
                }
            }.padding(24).frame(width:440)
        }
        .sheet(isPresented:$showingHostSession) { HostSessionView(model:model) }
        .focusedSceneValue(\.libraryMenuActions,menuActions)
        .focusedSceneValue(\.hostSessionAction,canShowHostSession ? { showingHostSession=true } : nil)
        .frame(minWidth:1000,minHeight:580)
        .task { model.libraryAppeared();await model.prepare() }
        .onChange(of:model.showingHome) { if model.showingHome { Task { await model.homeSync.refresh() } } }
        .onDisappear { model.libraryDisappeared() }
        .onChange(of:model.settings.value) { model.applyLiveSettings() }
    }
    @ViewBuilder private var library: some View {
        VStack(spacing:0) {
            hostLibraryHeader
            if let notice=model.library.notice {
                Label(notice,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).padding(12)
            }
            if model.library.apps.isEmpty {
                ContentUnavailableView(model.isBusy ? "Connecting to Host" : "Choose a Host",systemImage:"desktopcomputer",
                    description:Text(model.isBusy ? model.status : "Select a saved or nearby host, or add its address in the sidebar."))
            } else if model.library.filtered.isEmpty {
                ContentUnavailableView.search(text:model.library.query)
            } else if model.settings.value.libraryLayout == "list" {
                List(model.library.filtered,selection:Bindable(model.library).selectedID) { app in
                    Label { HStack { VStack(alignment:.leading) { Text(app.name);if let store=model.library.game(app)?.store { Text(store.name).font(.caption).foregroundStyle(.secondary) } };Spacer();if model.library.isRunning(app) { Text("Running").font(.caption).foregroundStyle(.green) };if app.hdrSupported { Text("HDR").font(.caption).foregroundStyle(.secondary) } } }
                        icon: { Image(systemName:app.name == "Desktop" ? "desktopcomputer" : "gamecontroller") }
                        .tag(app.id)
                        .task(id:"\(model.library.artworkID):\(app.id)") { await model.library.loadArtwork(app.id) }
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel(describe(app).label)
                        .accessibilityValue(describe(app).value)
                }
                .listStyle(.inset)
                .accessibilityLabel(libraryLabel)
                // Return and double-click start the selected app, as they open items in Finder.
                .contextMenu(forSelectionType:Int32.self) { ids in
                    if let id=ids.first { appMenu(id) }
                } primaryAction: { ids in
                    if let id=ids.first { start(id) }
                }
            } else {
                GameGrid(items:model.library.filtered,selection:Bindable(model.library).selectedID,label:libraryLabel,
                         open:{ start($0.id) },describe:describe) { app in
                    VStack(spacing:8) {
                        GameArtwork(data:model.library.artwork[app.id],desktop:app.name == "Desktop")
                            .aspectRatio(2/3,contentMode:.fit)
                        Text(app.name).font(.callout).lineLimit(2).frame(maxWidth:.infinity)
                        if let store=model.library.game(app)?.store { Text(store.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if model.library.isRunning(app) { Label("Running",systemImage:"play.fill").font(.caption).foregroundStyle(.green) }
                    }
                    .task(id:"\(model.library.artworkID):\(app.id)") { await model.library.loadArtwork(app.id) }
                    .contextMenu { appMenu(app.id) }
                }
            }
            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(2)
                Spacer()
                if !model.library.apps.isEmpty { Text("\(model.library.filtered.count) \(model.library.filtered.count == 1 ? "app" : "apps")") }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .disabled(model.hasSession || model.isBusy)
        .searchable(text:Bindable(model.library).query,prompt:"Search Apps")
        .searchFocused($searchFocused)
        .focusedSceneValue(\.librarySearchAction, { searchFocused=true })
    }
    private var hostLibraryHeader: some View {
        VStack(spacing:12) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                HStack(spacing:8) {
                    Button("Session and Graphics",systemImage:"rectangle.connected.to.line.below") { showingHostSession=true }
                        .disabled(!canShowHostSession)
                        .help("Session and graphics controls")
                    Button("Refresh Library",systemImage:"arrow.clockwise") { model.refreshLibrary() }
                        .disabled(model.phase != .ready || model.host?.paired != true)
                        .help("Refresh this PC's library")
                    Menu("Filter and Sort",systemImage:"line.3.horizontal.decrease") {
                        Toggle("HDR Apps Only",isOn:Bindable(model.library).hdrOnly)
                        Picker("Sort Apps",selection:setting(\.librarySort)) {
                            Text("Name").tag("name");Text("Host Order").tag("host")
                        }
                    }.help("Filter and sort apps")
                }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
            }
            HStack {
                Text("View").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Library View",selection:setting(\.libraryLayout)) {
                    Label("Grid",systemImage:"square.grid.2x2").tag("grid")
                    Label("List",systemImage:"list.bullet").tag("list")
                }.pickerStyle(.segmented).labelsHidden().frame(width:100).help("Choose Grid or List")
            }
        }.padding(12)
    }
    private func setting<T>(_ key: WritableKeyPath<StreamPreferences,T>) -> Binding<T> {
        Binding(get:{ model.settings.value[keyPath:key] },set:{ value in model.settings.update { $0[keyPath:key]=value } })
    }
    private var canShowHostSession: Bool { !model.showingHome && model.phase == .ready && model.host?.paired == true }
    private var menuActions: LibraryMenuActions {
        if model.showingHome {
            let game=model.home.games.first { $0.id == model.selectedHomeGameID }
            var actions=LibraryMenuActions()
            // A game on several PCs needs a choice of PC, which the details column offers.
            if let game,game.copies.count == 1,let copy=game.copies.first,let pc=model.home.pc(copy.hostID),!model.isBusy,!model.hasSession {
                actions.play=("Play on \(pc.name)",{ Task { await model.openHomeGame(copy);if model.hasSession { openWindow(id:"stream") } } })
            }
            if let game { actions.favourite=(game.favourite,{ model.home.toggleFavourite(game.id) }) }
            if !model.homeSync.busy,!model.isBusy,!model.hasSession { actions.refresh={ Task { await model.homeSync.refresh() } } }
            return actions
        }
        var actions=LibraryMenuActions(layout:setting(\.libraryLayout))
        if model.canPlay { actions.play=(model.library.selectedRunning ? "Resume Stream" : "Start Stream",{ startStream() }) }
        if model.phase == .ready,model.host?.paired == true { actions.refresh={ model.refreshLibrary() } }
        return actions
    }
    private var libraryLabel: String { "Apps on \(model.host?.name ?? "host")" }
    private func describe(_ app: HostApp) -> GameCardDescription {
        var value: [String]=[]
        if let store=model.library.game(app)?.store { value.append(store.name) }
        if model.library.isRunning(app) { value.append("Running") }
        if app.hdrSupported { value.append("HDR available") }
        var description=GameCardDescription(label:app.name,value:value.joined(separator:", "))
        if model.canPlay { description.actions=[(model.library.isRunning(app) ? "Resume Stream" : "Start Stream",{ start(app.id) })] }
        return description
    }
    @ViewBuilder private func appMenu(_ id: Int32) -> some View {
        let running=model.library.apps.first { $0.id == id }.map(model.library.isRunning) ?? false
        Button(running ? "Resume Stream" : "Start Stream",systemImage:"play.fill") { start(id) }.disabled(!model.canPlay)
    }
    /// Selects `id` and starts it; does nothing while the library cannot play.
    private func start(_ id: Int32) {
        model.library.selectedID=id
        if model.canPlay { startStream() }
    }
    private func startStream() {
        Task { await model.requestGameAction(startSelected:true);if model.hasSession { openWindow(id:"stream") } }
    }
    private var streamDetails: some View {
        Form {
            if let error=model.errorMessage { Section { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) } }
            if let app=model.library.selected {
                Section {
                    GameArtwork(data:model.library.artwork[app.id],desktop:app.name == "Desktop").frame(height:180)
                        .task(id:"\(model.library.artworkID):\(app.id)") { await model.library.loadArtwork(app.id) }
                    Label(app.name,systemImage:app.name == "Desktop" ? "desktopcomputer" : "gamecontroller").font(.title2)
                    if let store=model.library.game(app)?.store { LabeledContent("Store",value:store.name) }
                    if model.library.selectedRunning { Label("Running on host",systemImage:"play.circle.fill").foregroundStyle(.green) }
                    if app.hdrSupported { Label("HDR available on host",systemImage:"sparkles").foregroundStyle(.secondary) }
                    Button(model.library.selectedRunning ? "Resume Stream" : "Start Stream",systemImage:"play.fill",action:startStream)
                        .buttonStyle(.borderedProminent).disabled(!model.canPlay)
                        .help("Return or double-click in the library also starts the selected app.")
                    if (model.host?.currentGame ?? 0) > 0 {
                        Button("Quit Running Game…",systemImage:"stop.circle",role:.destructive) {
                            Task { await model.requestGameAction(startSelected:false) }
                        }.disabled(model.phase != .ready || model.isBusy || model.host?.quitAllowed == false)
                        .help(model.host?.quitAllowed == false ? "The host has not granted permission to quit games." : "Confirm before quitting the running game.")
                    }
                }
                Section("Video") { GameVideoPreferencesView(model:model) }
                Section("Audio") { AudioPreferencesView(model:model) }
                Section { Text("Video settings are saved for future streams. Audio, microphone and clipboard settings remain global. Video and channel layout are fixed while streaming.").font(.caption).foregroundStyle(.secondary) }
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
            Label("Home",systemImage:"house.fill").tag("__home__").disabled(locked)
            Section("Saved Hosts") {
                ForEach(model.savedHosts.hosts) { host in
                    hostLabel(host.name,endpoint:host.endpoint).tag(host.id)
                        .contextMenu {
                            Button("Connect",systemImage:"network") { model.connect(to:host.endpoint) }.disabled(locked)
                            Button("Remove from Saved Hosts",systemImage:"minus.circle") { model.removeSavedHost(host.endpoint) }.disabled(locked)
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

struct GameArtwork: View {
    let data: Data?
    let desktop: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius:8).fill(.quaternary)
                if let data,let image=NSImage(data:data) {
                    Image(nsImage:image).resizable().scaledToFit()
                } else {
                    Image(systemName:desktop ? "desktopcomputer" : "gamecontroller")
                        .font(.largeTitle).foregroundStyle(.tint)
                }
            }.frame(width:geometry.size.width,height:geometry.size.height).clipShape(RoundedRectangle(cornerRadius:8))
        }.accessibilityHidden(true)
    }
}

extension VideoFormat {
    var displayName: String {
        let codec=isH264 ? "H.264" : (isAV1 ? "AV1" : "HEVC")
        return "\(codec) · \(tenBit ? "10" : "8")-bit · \(chroma444 ? "4:4:4" : "4:2:0")"
    }
}
