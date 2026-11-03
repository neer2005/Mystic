import SwiftUI
import AppKit
import MysticCore
import MysticKit
import MysticStream

public struct HostLibraryView: View {
    @Bindable private var model: ConnectionModel
    @State private var showingHostSession=false
    @State private var showingHostDetails=false
    @State private var filesModel: FilesModel?
    @State private var foldersModel: SharedFoldersModel?
    @State private var searchFocus=0
    @Environment(\.openWindow) private var openWindow
    /// A stream asked for on the command line, started once the library appears.
    private let startup: ShortcutLaunch?
    public init(model: ConnectionModel,startup: ShortcutLaunch? = nil) { self.model=model;self.startup=startup }
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
        // SwiftUI clears isPresented before a button's action runs, so clearing the pending choice
        // there would cancel the confirmation. Cancel (also Esc) is what cancels.
        .confirmationDialog(model.pendingGameAction?.question ?? "Quit Game",
                            isPresented:Binding(get:{ model.pendingGameAction != nil },set:{ _ in }),
                            titleVisibility:.visible,presenting:model.pendingGameAction) { action in
            Button(action.title,role:.destructive) {
                Task { await model.confirmGameAction(action);if model.hasSession { openWindow(id:"stream") } }
            }
            Button("Cancel",role:.cancel) { model.cancelGameAction() }
        } message: { action in Text(action.explanation) }
        .sheet(isPresented:$showingHostSession) { HostSessionView(model:model) }
        .sheet(isPresented:$showingHostDetails) { HostDetailsView(model:model) }
        .sheet(item:$filesModel) { FilesView(model:$0,hostName:model.host?.name ?? "PC") }
        .sheet(item:$foldersModel) { SharedFoldersView(model:$0,hostName:model.host?.name ?? "PC") }
        .focusedSceneValue(\.hostDetailsAction,canShowHostDetails ? { showingHostDetails=true } : nil)
        .focusedSceneValue(\.libraryMenuActions,menuActions)
        .focusedSceneValue(\.hostSessionAction,canShowHostSession ? { showingHostSession=true } : nil)
        .fullScreenCommandTarget()
        .frame(minWidth:1000,minHeight:580)
        .confirmationDialog(shortcutQuestion,isPresented:Binding(get:{ model.pendingShortcut != nil },set:{ _ in }),
                            titleVisibility:.visible) {
            Button("Start") { Task { await finish(model.confirmShortcut(),commandLine:false) } }
            Button("Cancel",role:.cancel) { model.cancelShortcut() }
        } message: { Text("A link asked Mystic to start this. Only continue if you opened it yourself.") }
        .onOpenURL { url in
            guard let shortcut=ShortcutLaunch.parse(url:url) else { return }
            Task { await finish(model.offer(shortcut),commandLine:false) }
        }
        .overlay(alignment:.bottomTrailing) {
            if let release=model.updates.found {
                VStack(alignment:.leading,spacing:8) {
                    Text("Mystic \(release.version) is available.")
                    HStack {
                        Button("Open Download Page") { model.updates.openPage() }.buttonStyle(.borderedProminent)
                        Button("Not Now") { model.updates.dismiss() }
                    }
                }
                .padding(14).background(.regularMaterial,in:.rect(cornerRadius:12)).padding(24)
            }
        }
        .task {
            model.libraryAppeared();await model.prepare()
            // Once per process: reopening the library window must not start it again.
            if let startup,!model.startupLaunchHandled {
                model.startupLaunchHandled=true
                await finish(model.offer(startup),commandLine:true)
            }
            await model.updates.startOnce(enabled:model.checkForUpdates)
        }
        .onChange(of:model.quickResumeLaunch) { if model.quickResumeLaunch != nil,model.hasSession { openWindow(id:"stream") } }
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
            if let host=model.host,!host.paired {
                // Both fill the pane so the header stays at the top.
                pairing(host).frame(maxHeight:.infinity)
            } else if model.library.apps.isEmpty {
                ContentUnavailableView {
                    Label(model.isBusy ? "Connecting to Host" : "Choose a Host",systemImage:"desktopcomputer")
                } description: {
                    Text(model.isBusy ? model.status : "Select a saved or nearby host, or add its address in the sidebar.")
                } actions: {
                    if model.isBusy,model.canDisconnect { Button("Cancel") { model.disconnect() } }
                }.frame(maxHeight:.infinity)
            } else if model.library.filtered.isEmpty {
                ContentUnavailableView.search(text:model.library.query).frame(maxHeight:.infinity)
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
                            .aspectRatio(GameArtwork.aspect,contentMode:.fit)
                        Text(app.name).font(.callout).lineLimit(2,reservesSpace:true).multilineTextAlignment(.center).frame(maxWidth:.infinity)
                        if let store=model.library.game(app)?.store { Text(store.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if model.library.isRunning(app) { Label("Running",systemImage:"play.fill").font(.caption).foregroundStyle(.green) }
                    }
                    .task(id:"\(model.library.artworkID):\(app.id)") { await model.library.loadArtwork(app.id) }
                } menu: { app in appMenu(app.id) }
            }
            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).lineLimit(2)
                Spacer()
                if !model.library.apps.isEmpty { Text("\(model.library.filtered.count) \(model.library.filtered.count == 1 ? "game" : "games")") }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .disabled(model.hasSession || model.isBusy)
        .focusedSceneValue(\.librarySearchAction, { searchFocus+=1 })
    }
    private var hostLibraryHeader: some View {
        VStack(spacing:12) {
            HStack {
                LibrarySearchField(text:Bindable(model.library).query,prompt:"Search \(model.host?.name ?? "Games")",focus:searchFocus)
                    .frame(maxWidth:320)
                Spacer()
                HStack(spacing:8) {
                    Picker("Library View",selection:setting(\.libraryLayout)) {
                        Label("Grid",systemImage:"square.grid.2x2").tag("grid")
                        Label("List",systemImage:"list.bullet").tag("list")
                    }.pickerStyle(.segmented).labelsHidden().help("Show games as a grid or a list")
                    Button("Refresh Library",systemImage:"arrow.clockwise") { model.refreshLibrary() }
                        .disabled(model.phase != .ready || model.host?.paired != true)
                        .help("Refresh this PC's library")
                    Menu("Filter and Sort",systemImage:"line.3.horizontal.decrease") {
                        Toggle("HDR Games Only",isOn:Bindable(model.library).hdrOnly)
                        Picker("Sort Games",selection:setting(\.librarySort)) {
                            Text("Name").tag("name");Text("PC's Order").tag("host")
                        }
                    }.help("Filter and sort games")
                    Menu("PC",systemImage:"ellipsis") {
                        Button("Host Controls…",systemImage:"slider.horizontal.3") { showingHostSession=true }
                            .disabled(!canShowHostSession)
                        if model.host?.nativeAPI == true {
                            Button("Files…",systemImage:"folder") { filesModel=model.openFiles() }
                                .disabled(!canShowHostDetails)
                            Button("Shared Folders…",systemImage:"externaldrive.connected.to.line.below") { foldersModel=model.openSharedFolders() }
                                .disabled(!canShowHostDetails)
                        }
                        Divider()
                        Button("Host Details…",systemImage:"info.circle") { showingHostDetails=true }
                            .disabled(!canShowHostDetails)
                    }.help("Host controls, files and details")
                }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(12)
    }
    private func setting<T>(_ key: WritableKeyPath<StreamPreferences,T>) -> Binding<T> {
        Binding(get:{ model.settings.value[keyPath:key] },set:{ value in model.settings.update { $0[keyPath:key]=value } })
    }
    private var canShowHostDetails: Bool { !model.showingHome && model.host != nil && !model.hasSession }
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
    /// Pairing happens where the library will appear, with the PIN shown inline.
    private func pairing(_ host: HostInfo) -> some View {
        ContentUnavailableView {
            Label("Pair with \(host.name)",systemImage:"lock.open")
        } description: {
            if let pin=model.pairingPIN {
                VStack(spacing:8) {
                    Text(pin).font(.system(size:44,weight:.semibold).monospacedDigit()).textSelection(.enabled)
                        .accessibilityLabel("PIN \(pin.map(String.init).joined(separator:" "))")
                    Text("Enter this PIN in \(host.name)'s pairing page.")
                }
            } else {
                Text("Pairing lets Mystic list and start this PC's games. You will enter a PIN on the host.")
            }
            if let error=model.pairingError { Text(error).foregroundStyle(.red) }
        } actions: {
            if model.phase == .pairing,model.pairingPIN == nil {
                ProgressView();Button("Cancel") { model.disconnect() }
            } else if model.pairingPIN == nil {
                VStack(spacing:12) {
                    Button("Pair") { model.pair() }.buttonStyle(.borderedProminent).disabled(model.phase != .ready)
                    if let link=host.webUI?.link { Link("Open Host Web UI",destination:link) }
                    if host.otpPairing != .never { OneTimePairingForm(model:model) }
                }
            } else {
                Button("Cancel") { model.disconnect() }
            }
        }
    }
    /// Names the game that will quit, which need not be the selected one.
    private var quitButton: some View {
        let name=model.library.runningApp?.name
        return Button(name.map { "Quit \($0)…" } ?? "Quit Running Game…",systemImage:"stop.circle",role:.destructive) {
            Task { await model.requestGameAction(startSelected:false) }
        }
        .disabled(model.phase != .ready || model.isBusy || model.host?.quitAllowed == false)
        .help(model.host?.quitAllowed == false ? "The host has not granted permission to quit games." : "Quits \(name ?? "the running game") on \(model.host?.name ?? "the host") after you confirm.")
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
    /// Context menus list only what can be done now, as the HIG asks; the menu bar keeps the full set.
    private var shortcutQuestion: String {
        guard let shortcut=model.pendingShortcut else { return "Start Stream" }
        return shortcut.app.map { "Start \($0) on \(shortcut.host)?" } ?? "Open \(shortcut.host)'s library?"
    }
    /// What a command line or link led to: the stream window, or why it did not start. A
    /// command line that cannot start ends Mystic with exit code 1, as Nightjar's does.
    private func finish(_ failure: String?,commandLine: Bool) async {
        if let failure {
            if commandLine {
                FileHandle.standardError.write(Data("Mystic: \(failure)\n".utf8))
                model.exitApp(1)
            }
            model.reportShortcutFailure(failure)
        } else if model.hasSession { openWindow(id:"stream") }
    }
    /// The same launch as a link or command line, for game frontends and shortcuts.
    private func shortcut(for id: Int32) -> ShortcutLaunch? {
        guard let host=model.host,let app=model.library.apps.first(where: { $0.id == id }) else { return nil }
        return ShortcutLaunch(host:host.uniqueID,app:app.uuid.isEmpty ? app.name : app.uuid)
    }
    @ViewBuilder private func appMenu(_ id: Int32) -> some View {
        let running=model.library.apps.first { $0.id == id }.map(model.library.isRunning) ?? false
        if model.phase == .ready,!model.isBusy,model.capabilities != nil {
            Button(running ? "Resume Stream" : "Start Stream",systemImage:"play.fill") { start(id) }
        }
        if running,model.library.runningApp?.id == id,model.phase == .ready,!model.isBusy,model.host?.quitAllowed != false {
            Button("Quit \(model.library.runningApp?.name ?? "Game")…",systemImage:"stop.circle",role:.destructive) {
                Task { await model.requestGameAction(startSelected:false) }
            }
        }
        if let shortcut=shortcut(for:id) {
            Divider()
            Button("Copy Launch Link",systemImage:"link") { copy(shortcut.link.absoluteString) }
            Button("Copy Command Line",systemImage:"terminal") {
                copy(shortcut.commandLine(executable:Bundle.main.executablePath ?? "Mystic.app/Contents/MacOS/MysticApp"))
            }
        }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
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
                    HStack(alignment:.top,spacing:12) {
                        GameArtwork(data:model.library.artwork[app.id],desktop:app.name == "Desktop")
                            .frame(width:72,height:108)
                            .task(id:"\(model.library.artworkID):\(app.id)") { await model.library.loadArtwork(app.id) }
                        VStack(alignment:.leading,spacing:4) {
                            Text(app.name).font(.title3.weight(.semibold)).lineLimit(3)
                            let facts=[model.library.game(app)?.store?.name,app.hdrSupported ? "HDR" : nil].compactMap { $0 }
                            if !facts.isEmpty { Text(facts.joined(separator:" · ")).foregroundStyle(.secondary) }
                            if model.library.selectedRunning { Label("Running",systemImage:"play.circle.fill").foregroundStyle(.green) }
                        }
                    }
                    Button(model.library.selectedRunning ? "Resume Stream" : "Start Stream",systemImage:"play.fill",action:startStream)
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canPlay)
                        .help("Return or double-click in the library also starts the selected app.")
                    if (model.host?.currentGame ?? 0) > 0 { quitButton }
                }
                Section("Video") {
                    GameVideoPreferencesView(model:model)
                    if let profile=model.activeNetworkProfile {
                        LabeledContent("Network Profile",value:profile.name)
                        Text("On \(model.networkKind?.label.lowercased() ?? "this network"), \(profile.name) changes: \(profile.overrides.summary).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Leaving") {
                    Toggle("Quit Game When Leaving",isOn:$model.quitsOnLeave).disabled(model.hostProfileKey == nil)
                    Text("Disconnecting from this game's stream also quits it on the PC. A lost connection never does.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Audio") { AudioPreferencesView(model:model) }
                Section { Text("Video settings are saved for each game. Audio settings are shared by all games.").font(.caption).foregroundStyle(.secondary) }
            } else { Section { Text("Select a game to see its options.").foregroundStyle(.secondary) } }
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
    @State private var checkingRemote=false
    private var locked: Bool { model.hasSession || model.isBusy }
    var body: some View {
        List(selection:Binding(get:{model.selectedHostEndpointID},set:{model.selectHost($0)})) {
            Label("Home",systemImage:"house.fill").tag("__home__").disabled(locked)
            Section("Saved Hosts") {
                ForEach(model.savedHosts.hosts) { host in
                    hostRow(host.name,endpoint:host.endpoint,id:host.id)
                        .contextMenu {
                            if isActive(host.id) {
                                Button("Disconnect",systemImage:"eject") { model.leave() }.disabled(!model.canDisconnect)
                                Button("Check Remote Access…",systemImage:"globe") { checkingRemote=true }.disabled(!model.remoteCheck.available)
                            } else if !locked {
                                Button("Connect",systemImage:"network") { model.connect(to:host.endpoint) }
                            }
                            if !locked { Button("Remove from Saved Hosts",systemImage:"minus.circle") { model.removeSavedHost(host.endpoint) } }
                        }
                        .help("\(host.endpoint.id). Removing from Saved Hosts keeps its Keychain pairing.")
                }
            }
            Section("Nearby Hosts") {
                ForEach(model.discovery.hosts.filter { nearby in !model.savedHosts.hosts.contains { $0.id == nearby.id } }) { host in
                    hostRow(host.name,endpoint:host.endpoint,id:host.id)
                }
                Text(model.discovery.status).font(.caption).foregroundStyle(.secondary)
                if model.settings.value.discoveryEnabled {
                    Button("Search Again") { model.discovery.refresh() }.buttonStyle(.link).font(.caption)
                }
            }
            Section {
                DisclosureGroup("Add Host",isExpanded:$addingHost) {
                    TextField("Address or Pairing Link",text:$model.address,prompt:Text("192.168.1.100"))
                        .textFieldStyle(.roundedBorder).onSubmit { connectEntered() }
                    TextField("HTTP Port",text:$model.port).textFieldStyle(.roundedBorder)
                    Button("Connect",systemImage:"network") { connectEntered() }
                    Button("Paste Pairing Link",systemImage:"doc.on.clipboard") { model.connectFromClipboard() }
                        .help("Pairs with the link from Copy pairing link on the PC's Devices page.")
                }.disabled(locked)
            }
            if let error=model.savedHosts.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .listStyle(.sidebar)
        .onAppear { addingHost=model.savedHosts.hosts.isEmpty }
        .toolbar { ToolbarItem { Button("Add Host",systemImage:"plus") { addingHost=true }.disabled(locked) } }
        .sheet(isPresented:$checkingRemote) { RemoteCheckView(check:model.remoteCheck) }
    }
    /// A pairing link typed or pasted in the address field holds secrets: it leaves the field.
    private func connectEntered() {
        guard ConnectionModel.isPairingLink(model.address) else { model.connect();return }
        let link=model.address
        model.address=""
        model.connect(pairingLink:link)
    }
    private func isActive(_ id: String) -> Bool { !model.showingHome && model.selectedHostEndpointID == id }
    /// The connected host's row carries its state and an eject button, as Finder does for servers.
    private var activeStatus: String {
        switch model.phase {
        case .connecting,.launching: "Connecting…"
        case .pairing: model.pairingPIN == nil ? "Pairing…" : "Waiting for PIN"
        case .reconnecting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        case .streaming: "Streaming"
        case .failed: "Needs attention"
        case .idle,.ready: model.host.map { $0.paired ? "Connected" : "Pairing required" } ?? "Connecting…"
        }
    }
    private func hostRow(_ name: String,endpoint: HostEndpoint,id: String) -> some View {
        let active=isActive(id)
        return HStack {
            Label {
                VStack(alignment:.leading,spacing:2) {
                    Text(name)
                    Text(active ? activeStatus : endpoint.id).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName:"desktopcomputer") }
            Spacer(minLength:0)
            if active {
                Button("Disconnect from \(name)",systemImage:"eject.fill") { model.leave() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!model.canDisconnect)
                    .help("Disconnect from \(name)")
            }
        }
        .tag(id)
        .disabled(locked && !active)
    }
}

/// Cover art in a 2:3 frame. Art of that shape fills it; other shapes, such as square
/// store art, are fitted over a blurred fill of themselves so every card has the same
/// edges instead of gray bars. Overlays keep the frame's size fixed whatever the art.
struct GameArtwork: View {
    let data: Data?
    let desktop: Bool
    static let aspect: CGFloat=2/3
    private var image: NSImage? { data.flatMap(NSImage.init(data:)).flatMap { $0.size.height > 0 ? $0 : nil } }
    var body: some View {
        let image=image
        let fills=image.map { abs($0.size.width/$0.size.height/Self.aspect-1) < 0.04 } ?? false
        // Each layer is its own overlay so both are sized to the frame, not to each other.
        Rectangle().fill(.quaternary)
            .overlay {
                if let image,!fills { Image(nsImage:image).resizable().scaledToFill().blur(radius:20).opacity(0.7) }
            }
            .overlay {
                if let image {
                    if fills { Image(nsImage:image).resizable().scaledToFill() }
                    else { Image(nsImage:image).resizable().scaledToFit() }
                } else {
                    Image(systemName:desktop ? "desktopcomputer" : "gamecontroller")
                        .font(.largeTitle).foregroundStyle(.tint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius:8))
            .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(.separator,lineWidth:0.5) }
            .accessibilityHidden(true)
    }
}

extension VideoFormat {
    var displayName: String {
        let codec=isH264 ? "H.264" : (isAV1 ? "AV1" : "HEVC")
        return "\(codec) · \(tenBit ? "10" : "8")-bit · \(chroma444 ? "4:4:4" : "4:2:0")"
    }
}

/// Inline, as PIN pairing is: a PIN and passphrase made in the host's web UI, valid three minutes.
private struct OneTimePairingForm: View {
    let model: ConnectionModel
    @State private var shown=false
    @State private var pin=""
    @State private var passphrase=""
    var body: some View {
        DisclosureGroup("Use a One-Time PIN",isExpanded:$shown) {
            VStack(alignment:.leading,spacing:8) {
                Text("Create a one-time PIN and passphrase in the host's web UI, then enter them here.").font(.caption).foregroundStyle(.secondary)
                TextField("PIN",text:$pin).textFieldStyle(.roundedBorder)
                SecureField("Passphrase",text:$passphrase).textFieldStyle(.roundedBorder)
                Button("Pair with One-Time PIN") {
                    model.pair(oneTimePIN:pin,passphrase:passphrase)
                    passphrase=""
                }.disabled(pin.isEmpty || passphrase.isEmpty)
            }.frame(width:280)
        }.frame(width:300)
    }
}

/// A PC's details, as Nightjar's: its host software, what it lets this Mac do, and its web UI.
struct HostDetailsView: View {
    let model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing:0) {
            Form {
                if let host=model.host {
                    Section(host.name) {
                        LabeledContent("Software",value:host.software ?? "Moonlight-compatible host")
                        if let version=host.appVersion { LabeledContent("Protocol Version",value:version) }
                        LabeledContent("Address",value:model.hostAddressLabel)
                        LabeledContent("Pairing",value:host.paired ? "Paired" : "Not paired")
                    }
                    if let web=host.webUI {
                        Section("Web UI") {
                            if let link=web.link {
                                LabeledContent(link.absoluteString) { Link("Open in Browser",destination:link) }
                                Text("Manage the host's applications, paired devices and settings. Your browser may warn about the host's own certificate.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let problem=web.problem {
                                Text(problem).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let permissions=host.permissions {
                        Section("Allowed for This Mac") {
                            if permissions.isEmpty { Text("Nothing yet. Set this device's permissions in the host's web UI.").foregroundStyle(.secondary) }
                            ForEach(permissions,id:\.self) { Label($0,systemImage:"checkmark") }
                        }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Spacer();Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }.frame(width:460,height:440)
    }
}
