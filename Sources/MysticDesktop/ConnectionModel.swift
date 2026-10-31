import AVFoundation
import GameController
import AppKit
import Foundation
import Observation
import MysticKit
import MysticStream
import MysticCore

/// Owns the connection to one host and the stream on it: connect, pair, launch,
/// recovery and disconnect. Each feature keeps its own state in a model below, which
/// checks `generation` so results from an older connection are dropped.
@MainActor @Observable
public final class ConnectionModel {
    public enum Phase: String { case idle, connecting, pairing, ready, launching, streaming, reconnecting, disconnecting, failed }
    public var address: String
    public var port: String
    public let savedHosts: SavedHosts
    public let discovery: HostDiscovery
    public let settings: AppSettings
    public let profiles: StreamProfilesStore
    public let home: HomeLibrary

    @ObservationIgnored public private(set) lazy var library = AppLibraryModel(model:self)
    @ObservationIgnored public private(set) lazy var homeSync = HomeSync(model:self)
    @ObservationIgnored public private(set) lazy var rates = StreamRatesModel(model:self)
    @ObservationIgnored public private(set) lazy var sessionControls = HostSessionModel(model:self)
    @ObservationIgnored public private(set) lazy var graphics = HostGraphicsModel(model:self)

    public private(set) var phase: Phase = .idle
    public private(set) var status = "Enter your host’s LAN address to connect."
    public private(set) var errorMessage: String?
    public private(set) var host: HostInfo?
    public private(set) var pairingPIN: String?
    public private(set) var capabilities: VideoCapabilities?
    public private(set) var presenter: DisplayLayerPresenter?
    public private(set) var inputCapture: StreamInputCapture?
    public private(set) var videoTelemetry: VideoTelemetrySnapshot?
    public private(set) var diagnostics: [String] = []
    /// The app the current stream launched; the stream window's title.
    public private(set) var streamingAppName: String?

    public var isBusy: Bool { pendingGameAction != nil || rates.busy || sessionControls.busy || graphics.writing || [.connecting, .pairing, .launching, .reconnecting, .disconnecting].contains(phase) }
    public var canPlay: Bool { phase == .ready && !isBusy && library.selected != nil && capabilities != nil }
    public var hasSession: Bool { phase == .streaming || phase == .launching || phase == .reconnecting }
    public var canDisconnect: Bool { phase != .idle && phase != .disconnecting }
    /// Identifies the current connection for actions confirmed in a sheet; stale ones are ignored.
    public var contextID: UUID { generation }

    public private(set) var clipboardStatus="Clipboard sharing idle"
    public private(set) var clipboardBusy=false
    public var canSendClipboard: Bool { phase == .streaming && clipboard?.canSend == true && !clipboardBusy }
    public var canReadClipboard: Bool { phase == .streaming && clipboard?.canRead == true && !clipboardBusy }
    public func sendClipboardToHost() { clipboard?.sendTextToHost() }
    public func copyHostClipboard() { clipboard?.copyTextFromHost() }
    public var microphoneMuted=false { didSet { session?.setMicrophoneMuted(microphoneMuted) } }
    public private(set) var microphoneStatus="Microphone off"
    public private(set) var audioStatus = "Audio idle"
    public private(set) var audioOutputStatus: AudioOutputStatus = .idle
    public var canRetryAudio: Bool { phase == .streaming && audioOutputStatus == .unavailable }
    public func retryAudioOutput() { if canRetryAudio { audioPlayer?.retryOutput() } }

    public var showingHome=true
    public var selectedHomeGameID: String?
    public func showHome() { guard !isBusy,!hasSession else { return };showingHome=true }
    public func removeSavedHost(_ endpoint: HostEndpoint) {
        guard !isBusy,!hasSession else { return }
        homeSync.cancel();savedHosts.remove(endpoint);home.reconcile(savedHosts.hosts)
    }
    public func openHomeGame(_ copy: HomeInstallation) async {
        guard !isBusy,!hasSession,let pc=home.pc(copy.hostID) else { return }
        connect(to:pc.endpoint)
        let token=generation
        await operation?.value
        guard generation == token,phase == .ready,host?.paired == true,host?.uniqueID == pc.uniqueID else { return }
        let current=library.apps.first { candidate in
            copy.app.uuid.isEmpty ? (candidate.id == copy.app.id && candidate.name == copy.app.name) : candidate.uuid.caseInsensitiveCompare(copy.app.uuid) == .orderedSame
        }
        guard let current else { fail("This game is no longer in the host's library. Refresh Home and choose it again.");return }
        if let gameID=copy.gameID,!gameID.isEmpty,library.native?.game(appID:current.id)?.game_id != gameID {
            fail("The host's game identity changed. Refresh Home before launching it.");return
        }
        library.selectedID=current.id
        await requestGameAction(startSelected:true)
    }
    /// The Home entry for the connected host, where its artwork is cached.
    var connectedHomePC: HomePC? {
        guard let host,let target=HostEndpoint(address:connectedAddress,port:connectedPort) else { return nil }
        return home.pc(HomePC.key(uniqueID:host.uniqueID,endpoint:target))
    }

    public var selectedHostEndpointID: String? { showingHome ? "__home__" : (host != nil || isBusy || hasSession ? endpoint : nil) }
    public func selectHost(_ id: String?) {
        guard let id else { return }
        if id == "__home__" { showHome();return }
        if let endpoint=savedHosts.hosts.first(where: { $0.id == id })?.endpoint ?? discovery.hosts.first(where: { $0.id == id })?.endpoint {
            if id != selectedHostEndpointID { connect(to:endpoint) }
        }
    }
    public func refreshLibrary() {
        guard phase == .ready,!isBusy,let connection else { return }
        let token=generation
        library.beginReload()
        phase = .connecting
        operation=Task { [weak self] in
            do { try await self?.loadApps(connection,token:token) }
            catch { self?.fail(error.localizedDescription,token:token) }
        }
    }

    public struct GameAction: Identifiable {
        public let id=UUID()
        public let context: UUID
        public let running: HostInfo
        public let runningName: String
        public let target: HostApp?
        public var title: String { target.map { "Quit and Start \($0.name)" } ?? "Quit Game" }
    }
    public private(set) var pendingGameAction: GameAction?
    @ObservationIgnored private var pendingSwitchPlan: StreamPlan?
    public func cancelGameAction() { pendingGameAction=nil;pendingSwitchPlan=nil;if phase == .ready { status="Connected to \(host?.name ?? address)." } }
    public func requestGameAction(startSelected: Bool) async {
        guard phase == .ready,!isBusy,let connection else { return }
        let target=startSelected ? library.selected : nil
        if startSelected && target == nil { return }
        let token=generation
        phase = .connecting;errorMessage=nil;status="Checking the running game…"
        do {
            let info=try await connection.serverInfo()
            guard generation == token else { return }
            guard info.paired,info.uniqueID == host?.uniqueID else { throw HostConnectionError("The host identity or pairing changed. Connect again.") }
            host=info
            var prepared: StreamPlan?
            if let target {
                guard let capabilities else { throw HostConnectionError("Video capabilities are unavailable.") }
                library.selectedID=target.id
                prepared=try preparedPlan(app:target,capabilities:capabilities)
            }
            if prepared?.configuration.microphone == true {
                guard await microphonePermission() else { throw HostConnectionError("Allow microphone access or disable Use Mac Microphone before switching games.") }
                guard generation == token else { return }
            }
            phase = .ready
            if let prepared,let capabilities,info.currentGame == 0 || info.currentGame == target?.id {
                startPreparedPlan(prepared,connection:connection,capabilities:capabilities);return
            }
            guard info.currentGame > 0 else { status="No game is running on the host.";return }
            guard info.quitAllowed != false else { throw HostConnectionError("The host has not granted permission to quit games.") }
            pendingSwitchPlan=prepared
            pendingGameAction=GameAction(context:token,running:info,runningName:library.apps.first { $0.id == info.currentGame }?.name ?? "the running game",target:target)
            status="Confirm before quitting the running game."
        } catch { guard generation == token else { return };fail(error.localizedDescription) }
    }
    public func confirmGameAction(_ action: GameAction) async {
        guard generation == action.context,pendingGameAction?.id == action.id,phase == .ready,!sessionControls.busy,!graphics.writing,let connection else { return }
        let prepared=pendingSwitchPlan,token=generation
        cancelGameAction();phase = .connecting;status="Quitting \(action.runningName)…";errorMessage=nil
        do {
            try await connection.quitApp(expected:action.running)
            guard generation == token else { return }
            let fresh=try await connection.serverInfo()
            guard generation == token else { return }
            guard fresh.paired,fresh.uniqueID == action.running.uniqueID,fresh.currentGame == 0 else {
                throw HostConnectionError("The host did not become idle. Nothing else was launched.")
            }
            host=fresh
            if let prepared,let capabilities {
                library.selectedID=prepared.app.id
                startPreparedPlan(prepared,connection:connection,capabilities:capabilities)
            } else { try await loadApps(connection,token:token);status="The game was quit on the host." }
        } catch {
            guard generation == token else { return }
            // A declined or uncertain quit must never launch the replacement.
            if let fresh=try? await connection.serverInfo(),generation == token { host=fresh }
            guard generation == token else { return }
            fail(error.localizedDescription)
        }
    }

    /// The host ended its session at this device's request; never reconnect.
    func hostEnded(_ message: String) { disconnect();status=message }
    /// The stream cannot continue; the message explains why.
    func endStream(_ message: String) { endRecovery(message) }

    @ObservationIgnored private let microphonePermission: @Sendable () async -> Bool
    @ObservationIgnored private let rememberHost: Bool
    @ObservationIgnored let vault: any CredentialsStorage
    @ObservationIgnored let makeHost: @Sendable (String, UInt16, ClientIdentity, String?) throws -> any HostService
    @ObservationIgnored private(set) var connection: (any HostService)?
    @ObservationIgnored private var clipboard: StreamClipboard?
    @ObservationIgnored private(set) var session: (any StreamSessionService)?
    @ObservationIgnored private(set) var decoder: VideoToolboxDecoder?
    @ObservationIgnored private(set) var audioPlayer: AudioPlayer?
    @ObservationIgnored private var telemetry: VideoTelemetry?
    @ObservationIgnored private var rendererMetricsMonitor: Task<Void,Never>?
    @ObservationIgnored private var controllerFeedbackMonitor: Task<Void, Never>?
    @ObservationIgnored private var statisticsMonitor: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    /// Changes on connect, disconnect and recovery; async work checks it before applying results.
    @ObservationIgnored private(set) var generation = UUID()
    @ObservationIgnored private var libraryVisible=false
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var endpoint = ""
    @ObservationIgnored private var connectedAddress = ""
    @ObservationIgnored private var connectedPort: UInt16 = 47989

    struct StreamPlan {
        let app: HostApp
        let options: LaunchOptions
        let configuration: StreamConfiguration
        let adaptive: Bool
        let reconnect: Bool
        let hostID: String
        let framePacing: FramePacingMode
    }
    @ObservationIgnored private(set) var plan: StreamPlan?
    @ObservationIgnored private var recovery = StreamRecovery()
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var hadVideo = false
    @ObservationIgnored private var connectedAt: UInt64?
    @ObservationIgnored var makeSession: (@escaping @Sendable () -> Void, @escaping @Sendable (String) -> Void) throws -> any StreamSessionService = {
        try StreamSession(inputFailure:$0,recoveryFailure:$1)
    }
    @ObservationIgnored var sleepForRecovery: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(for:.milliseconds($0)) }
    @ObservationIgnored var nowMillis: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds/1_000_000 }

    public init(vault: any CredentialsStorage = CredentialsVault(), rememberHost: Bool = true,
                microphonePermission: @escaping @Sendable () async -> Bool = {
                    switch AVCaptureDevice.authorizationStatus(for:.audio) {
                    case .authorized: return true
                    case .notDetermined: return await AVCaptureDevice.requestAccess(for:.audio)
                    default:return false
                    }
                },preferences: (any HostPreferencesStorage)? = HostPreferences(),settings: AppSettings? = nil,profiles: StreamProfilesStore? = nil,home: HomeLibrary? = nil,discovery: HostDiscovery = HostDiscovery(),
                makeHost: @escaping @Sendable (String, UInt16, ClientIdentity, String?) throws -> any HostService = {
                    try HostConnection(address: $0, port: $1, identity: $2, certificate: $3)
                }) {
        self.home=home ?? HomeLibrary(defaults:rememberHost ? .standard : nil,artRoot:rememberHost ? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.appendingPathComponent("com.mystic.streaming/HomeArt",isDirectory:true) : nil)
        self.microphonePermission=microphonePermission
        self.settings=settings ?? AppSettings(storage:rememberHost ? SettingsPreferences() : nil)
        self.profiles=profiles ?? StreamProfilesStore(storage:rememberHost ? StreamProfilePreferences() : nil)
        self.savedHosts=SavedHosts(storage:rememberHost ? preferences : nil);self.discovery=discovery
        self.vault = vault; self.makeHost = makeHost; self.rememberHost = rememberHost
        address = savedHosts.hosts.first?.endpoint.address ?? UserDefaults.standard.string(forKey: "lastHost") ?? ""
        port = savedHosts.hosts.first.map { String($0.endpoint.port) } ?? UserDefaults.standard.string(forKey: "lastPort") ?? "47989"
    }
    public func libraryAppeared() { libraryVisible=true;applyLiveSettings() }
    public func libraryDisappeared() { libraryVisible=false;discovery.stop();homeSync.cancel() }
    public func applyLiveSettings() {
        audioPlayer?.setVolume(volume,muted:muted)
        if libraryVisible && settings.value.discoveryEnabled { discovery.start() } else { discovery.stop() }
    }
    public func prepare() async {
        guard capabilities == nil, !probing else { return }
        probing = true
        capabilities = await VideoCapabilities.probe()
        probing = false
    }
    public func connect() {
        guard !isBusy, !hasSession else { return }
        showingHome=false;homeSync.cancel()
        guard let port=UInt16(port),let target=HostEndpoint(address:address,port:port) else {
            fail("Enter a host name or IP address, and an HTTP port from 1 to 65535."); return
        }
        let address=target.address
        connection?.cancel(); operation?.cancel()
        let token = UUID(); generation = token
        self.endpoint = target.id
        connectedAddress = address;connectedPort=port
        let endpoint = self.endpoint, vault = vault, factory = makeHost
        phase = .connecting; status = "Loading client identity from Keychain…"; errorMessage = nil
        cancelGameAction()
        rates.resetManual()
        graphics.reset()
        sessionControls.reset()
        library.clear()
        host = nil; pairingPIN = nil; diagnostics = []
        operation = Task { [weak self] in
            do {
                let connection = try await Task.detached {
                    try factory(address, port, vault.identity(), vault.certificate(for: endpoint))
                }.value
                guard let self, self.generation == token else { connection.cancel(); return }
                self.connection = connection
                self.status = "Connecting to \(address)…"
                let info = try await connection.serverInfo()
                guard self.generation == token else { return }
                self.host = info
                if info.paired { try await self.loadApps(connection, token: token) }
                else {
                    self.rememberConnectedHost(info)
                    self.phase = .ready; self.status = "Pair with \(info.name) to view its apps." }
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
    }
    public func connect(to endpoint: HostEndpoint) {
        guard !isBusy,!hasSession else { return }
        address=endpoint.address;port=String(endpoint.port);connect()
    }
    private func rememberConnectedHost(_ info: HostInfo) {
        guard rememberHost,let target=HostEndpoint(address:connectedAddress,port:connectedPort) else { return }
        savedHosts.remember(endpoint:target,name:info.name,uniqueID:info.paired ? info.uniqueID : nil)
    }
    public func pair() {
        guard phase == .ready, host?.paired == false, let connection else { return }
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        pairingPIN = pin; phase = .pairing; status = "Enter this PIN in your host’s pairing page."
        errorMessage = nil
        let token = generation, vault = vault, endpoint = endpoint
        operation = Task { [weak self] in
            do {
                let paired = try await connection.pair(pin: pin)
                guard let self, self.generation == token else { return }
                try await Task.detached { try vault.saveCertificate(paired.certificate, for: endpoint) }.value
                guard self.generation == token else { return }
                self.pairingPIN = nil
                self.host = try await connection.serverInfo()
                guard self.generation == token else { return }
                guard self.host?.paired == true else { throw HostConnectionError("The host did not confirm pairing.") }
                try await self.loadApps(connection, token: token)
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
    }
    private func loadApps(_ connection: any HostService, token: UUID) async throws {
        status="Loading game library…"
        let previous=library.selectedID
        let list = try await connection.apps()
        guard generation == token else { return }
        var native: HostLibrary?
        var notice: String?
        do { native = try await connection.library() }
        catch { notice="Game library unavailable; showing host apps. \(error.localizedDescription)" }
        guard generation == token else { return }
        let wake=try? await connection.wakeTargets()
        guard generation == token else { return }
        if let host {
            rememberConnectedHost(host)
            if let target=HostEndpoint(address:connectedAddress,port:connectedPort),notice == nil || home.pc(HomePC.key(uniqueID:host.uniqueID,endpoint:target)) == nil {
                home.record(host:host,endpoint:target,apps:native?.merging(apps:list) ?? list,library:native,wake:wake)
            }
        }
        library.replace(apps:list,library:native,notice:notice,keeping:previous)
        phase = .ready
        status = library.apps.isEmpty ? "The host has no streamable apps configured." : "Connected to \(host?.name ?? address)."
    }

    private func preparedPlan(app: HostApp,capabilities: VideoCapabilities) throws -> StreamPlan {
            let video=effectiveVideoSettings
            let dims = video.resolution.split(separator: "x").compactMap { UInt32($0) }
            guard dims.count == 2 else { throw HostConnectionError("Invalid stream resolution.") }
            var mask: UInt32 = capabilities.supportedFormats
            switch video.codec {
            case "h264": mask &= 0xF
            case "hevc": mask &= 0xF00
            case "av1": mask &= 0xF000
            default: break
            }
            mask &= video.hdr ? 0xAA00 : ~UInt32(0xAA00)
            guard mask != 0 else { throw HostConnectionError("This Mac has no verified hardware decoder for the selected codec and HDR mode.") }
            guard !video.hdr || app.hdrSupported else { throw HostConnectionError("This app does not advertise HDR support.") }
            var options = LaunchOptions(app: app)
            switch audioLayout {
            case "5.1": options.channelCount = 6; options.channelMask = 0x3F
            case "7.1": options.channelCount = 8; options.channelMask = 0x63F
            default: break
            }
            options.gamepadMask = UInt16((1 << min(4,GCController.controllers().filter { $0.extendedGamepad != nil }.count))-1)
            options.clipboardSync=clipboardSync
            options.width = dims[0]; options.height = dims[1]; options.fps = video.fps; options.hdr = video.hdr
            var config = StreamConfiguration()
            config.width = Int32(dims[0]); config.height = Int32(dims[1]); config.fps = Int32(video.fps)
            config.bitrateKbps = video.bitrateMbps * 1000; config.supportedVideoFormats = mask
            config.colorSpace = video.hdr ? 2 : 1; config.colorRange = 0
            config.microphone = microphoneEnabled
            config.channelCount = options.channelCount; config.channelMask = options.channelMask
            return StreamPlan(app:app,options:options,configuration:config,
                adaptive:video.adaptiveBitrate,reconnect:settings.value.automaticReconnect ?? true,
                hostID:host?.uniqueID ?? "",framePacing:video.framePacing)
    }
    private func startPreparedPlan(_ plan: StreamPlan,connection: any HostService,capabilities: VideoCapabilities) {
        recovery=StreamRecovery();recovering=false;hadVideo=false;connectedAt=nil
        self.plan=plan;streamingAppName=plan.app.name
        launchStream(plan,connection:connection,capabilities:capabilities)
    }
    public func play() {
        guard canPlay,let connection,let app=library.selected,let capabilities else { return }
        do { startPreparedPlan(try preparedPlan(app:app,capabilities:capabilities),connection:connection,capabilities:capabilities) }
        catch { fail(error.localizedDescription) }
    }
    private func launchStream(_ plan: StreamPlan, connection: any HostService, capabilities: VideoCapabilities) {
        let app = plan.app, config = plan.configuration
        var options = plan.options
        options.resumeOnly = recovering
        let token = generation
        rates.prepareLaunch()
        let adaptive = plan.adaptive
        videoTelemetry = nil
        phase = .launching; status = "Launching \(app.name)…"; errorMessage = nil
        let address = connectedAddress,permission = microphonePermission
        microphoneStatus = microphoneEnabled ? "Waiting for microphone permission…" : "Microphone off"
        operation = Task { [weak self, config] in
            do {
                if config.microphone {
                    guard await permission() else {
                        if self?.generation == token { self?.microphoneStatus="Microphone permission denied" }
                        throw HostConnectionError("Allow Mystic microphone access in System Settings → Privacy & Security → Microphone, or turn off Use Mac Microphone.")
                    }
                }
                guard let self,self.generation == token else { return }
                let launch = try await connection.launch(options)
                guard self.generation == token else { return }
                var config = config
                config.remoteInputAESKey = launch.key; config.remoteInputAESIV = launch.iv
                let session = try self.makeSession( { [weak self] in
                    Task { @MainActor in self?.streamFailed("Remote input delivery failed. The stream was stopped to release held keys.",token:token) }
                },{ [weak self] message in
                    Task { @MainActor in self?.record(message,token:token) }
                })
                let telemetry = VideoTelemetry()
                self.telemetry = telemetry
                let presenter = DisplayLayerPresenter(telemetry:telemetry,mode:plan.framePacing,onFailure: { [weak self] message in
                    Task { @MainActor in self?.record(message, token: token) }
                })
                let decoder = VideoToolboxDecoder(capabilities: capabilities, presenter: presenter, telemetry:telemetry,requestRecovery:{ [weak session] in session?.requestVideoRecovery() },log: { [weak self] message in
                    Task { @MainActor in self?.record(message, token: token) }
                })
                let audio = AudioPlayer(log: { [weak self] message in
                    Task { @MainActor in self?.record(message, token: token) }
                })
                audio.setVolume(self.volume, muted: self.muted)
                self.audioPlayer = audio
                self.inputCapture = StreamInputCapture(send: { [weak session] in session?.send($0) ?? false },failure: { [weak self] message in self?.record(message,token:token) })
                self.presenter = presenter; self.decoder = decoder; self.session = session
                self.status = "Starting video connection…"
                session.start(host: address, launch: launch, configuration: config, decoder: decoder, audio: audio,
                    event: { [weak self] event in Task { @MainActor in self?.handle(event, token: token) } },
                    failure: { [weak self] failure in Task { @MainActor in self?.startupFailed(failure, token: token) } },
                    microphoneMuted:self.microphoneMuted,microphoneStatus:{ [weak self] message in
                        Task { @MainActor in guard let self,self.generation == token else { return };self.microphoneStatus=message }
                    })
                self.clipboard?.stop()
                self.clipboard=StreamClipboard(host:connection,
                    canRead:launch.clipboardRead ?? self.host?.clipboardRead ?? false,
                    canSend:launch.clipboardWrite ?? self.host?.clipboardWrite ?? false,
                    syncEnabled:options.clipboardSync,isActive:{ [weak self] in self?.generation == token && self?.phase == .streaming && self?.inputCapture?.clipboardActive == true },
                    step:{ active,baseline,text in try await session.clipboardStep(active:active,baseline:baseline,text:text) },
                    report:{ [weak self] message,busy in
                        guard let self,self.generation == token else { return }
                        self.clipboardStatus=message;self.clipboardBusy=busy
                    })
                self.rates.streamStarted(launch:launch,adaptive:adaptive,configuration:config)
                self.monitorMedia(audio, telemetry:telemetry,token: token)
            } catch {
                guard let self,self.generation == token else { return }
                if self.recovering, (error as? HostConnectionError)?.retryable == true {
                    self.scheduleRecovery(error.localizedDescription)
                } else if self.recovering { self.endRecovery(error.localizedDescription) }
                else { self.fail(error.localizedDescription, token: token) }
            }
        }
    }
    #if DEBUG
    public func simulateVideoLoss() {
        guard phase == .streaming else { return }
        decoder?.simulateFrameLoss()
    }
    #endif
    public func disconnect() {
        homeSync.cancel()
        clipboard?.stop();clipboard=nil;clipboardBusy=false;clipboardStatus="Clipboard sharing idle"
        plan=nil;streamingAppName=nil;recovering=false;hadVideo=false;connectedAt=nil;recovery=StreamRecovery()
        rates.stopAutomatic(status:"Fixed bitrate")
        inputCapture?.setAvailable(false);inputCapture = nil
        generation = UUID(); let token = generation
        microphoneStatus="Microphone off"
        telemetry = nil; videoTelemetry = nil
        rendererMetricsMonitor?.cancel();rendererMetricsMonitor=nil
        controllerFeedbackMonitor?.cancel();controllerFeedbackMonitor=nil
        statisticsMonitor?.cancel(); statisticsMonitor = nil; audioStatus = "Audio stopped";audioOutputStatus = .idle
        operation?.cancel(); connection?.cancel(); connection = nil; pairingPIN = nil
        cancelGameAction()
        rates.resetManual()
        graphics.reset()
        sessionControls.reset()
        library.clear()
        host = nil
        guard let session else {
            decoder?.cleanup(); decoder = nil; presenter = nil; audioPlayer?.cleanup(); audioPlayer = nil
            phase = .idle; status = "Disconnected."; return
        }
        phase = .disconnecting; status = "Disconnecting…"
        session.stop { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.session = nil; self.decoder = nil; self.presenter = nil; self.audioPlayer = nil
                self.phase = .idle; self.status = "Disconnected. The app remains running on the host."
            }
        }
    }
    private func monitorMedia(_ player: AudioPlayer, telemetry: VideoTelemetry, token: UUID) {
        statisticsMonitor?.cancel()
        statisticsMonitor = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player, self.generation == token else { return }
                let snapshot = telemetry.snapshot()
                self.processMediaSnapshot(snapshot)

                await self.rates.refresh()
                guard self.generation == token else { return }
                let stats = player.statistics
                self.audioOutputStatus=stats.outputStatus
                let route=stats.outputDevice.map { " · "+$0 } ?? ""
                let rate=stats.outputSampleRate.map { String(format:" · %.1f kHz",$0/1000) } ?? ""
                let layout=stats.outputLayout.map { " · "+$0 } ?? ""
                let fallback=stats.stereoFallbackReason.map { " ("+$0+")" } ?? ""
                self.audioStatus = "\(stats.outputStatus.label)\(route)\(rate)\(layout)\(fallback): \(stats.decodedPackets) packets, \(stats.concealedPackets) concealed, \(stats.renderedFrames) frames rendered, \(stats.queuedFrames/48) ms queued · \(stats.outputRestarts) output restarts · \(stats.discardedOutputFrames) frames discarded during output changes"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func monitorRendererMetrics(_ presenter: DisplayLayerPresenter,token: UUID) {
        rendererMetricsMonitor?.cancel()
        rendererMetricsMonitor=Task { [weak self] in
            while !Task.isCancelled {
                guard self?.generation == token else { return }
                await presenter.refreshRendererMetrics()
                guard self?.generation == token,!Task.isCancelled else { return }
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
            }
        }
    }
    private func monitorControllerFeedback(_ session: any StreamSessionService,token: UUID) {
        controllerFeedbackMonitor?.cancel()
        controllerFeedbackMonitor=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.generation == token else { return }
                let epoch=self.inputCapture?.feedbackEpoch
                let values=await session.takeControllerFeedback()
                guard self.generation == token,!Task.isCancelled else { return }
                self.inputCapture?.applyControllerFeedback(values,epoch:epoch)
                do { try await Task.sleep(for:.milliseconds(16)) } catch { return }
            }
        }
    }
    private func handle(_ event: EngineEvent, token: UUID) {
        guard generation == token else { return }
        switch event {
        case .connected:
            connectedAt=nowMillis();inputCapture?.setAvailable(true);phase = .streaming
            if let plan,let target=HostEndpoint(address:connectedAddress,port:connectedPort) { home.played(hostID:HomePC.key(uniqueID:plan.hostID,endpoint:target),app:plan.app) }
            if let session { monitorControllerFeedback(session,token:token) }
            clipboard?.start()
            if let presenter { monitorRendererMetrics(presenter,token:token) }
            status = "Streaming \(plan?.app.name ?? library.selected?.name ?? "video")."
        case .stageStarting(let stage): status = "Starting \(stage.name)…"
        case .stageComplete: break
        case .stageFailed(let stage, let code): record("\(stage.name) failed (\(code)).", token: token)
        case .terminated(let code):
            connectionEnded(code:code,videoStarted:hadVideo || (telemetry?.snapshot().decoded ?? 0) > 0)
        case .log(let message):
            // Only our wrapper's setup diagnostics are safe here. Protocol logs may contain launch keys.
            if message.hasPrefix("video decoder rejected ") || message.hasPrefix("audio renderer rejected ") { record(message, token: token) }
        }
    }
    private func streamFailed(_ message: String, token: UUID) {
        guard generation == token else { return }
        endRecovery(message)
    }
    private func startupFailed(_ failure: StreamStartFailure, token: UUID) {
        guard generation == token else { return }
        if recovering,failure.retryable { scheduleRecovery(failure.message) }
        else { endRecovery(failure.message) }
    }
    /// Called after the generation check; the video flag survives attempts in one recovery chain.
    func connectionEnded(code: Int32, videoStarted: Bool) {
        if sessionControls.busy { sessionControls.streamTerminated();inputCapture?.setAvailable(false);return }
        let message="The host ended the stream (code \(code))."
        guard plan?.reconnect == true, StreamRecovery.recovers(code:code,videoStarted:videoStarted || hadVideo) else {
            endRecovery(message);return
        }
        hadVideo = true
        scheduleRecovery(message)
    }
    private func scheduleRecovery(_ message: String) {
        guard let plan,plan.reconnect else { endRecovery(message);return }
        let now=nowMillis()
        let duration=connectedAt.map { now >= $0 ? now-$0 : 0 } ?? 0
        connectedAt=nil
        guard let delay=recovery.nextDelay(nowMillis:now,connectedMillis:duration) else {
            endRecovery("Could not restore the stream within the retry limit. \(message)");return
        }
        clipboard?.stop();clipboard=nil;clipboardBusy=false;clipboardStatus="Clipboard sharing paused during recovery"
        cancelGameAction()
        rates.resetManual()
        graphics.reset()
        sessionControls.suspend()
        recovering=true;phase = .reconnecting;errorMessage=nil
        status="Connection interrupted. Reconnecting in \(delay/1000) seconds…"
        generation=UUID();let token=generation
        operation?.cancel();connection?.cancel();connection=nil
        inputCapture?.setAvailable(false);inputCapture=nil
        rendererMetricsMonitor?.cancel();rendererMetricsMonitor=nil
        controllerFeedbackMonitor?.cancel();controllerFeedbackMonitor=nil
        statisticsMonitor?.cancel();statisticsMonitor=nil
        rates.stopAutomatic()
        let previous=session;session=nil
        decoder=nil;presenter=nil;audioPlayer=nil;telemetry=nil;videoTelemetry=nil;rates.clearDecodedCount()
        let address=connectedAddress, port=connectedPort, endpoint=endpoint
        let factory=makeHost, vault=vault, sleep=sleepForRecovery
        operation=Task { [weak self] in
            if let previous { await withCheckedContinuation { continuation in previous.stop { continuation.resume() } } }
            do {
                try Task.checkCancellation()
                try await sleep(delay)
                guard let self,self.generation == token else { return }
                guard self.recovery.remaining(nowMillis:self.nowMillis()) > 0 else {
                    self.endRecovery("The reconnect window expired. Connect again when the host is reachable.");return
                }
                let connection=try await Task.detached { try factory(address,port,vault.identity(),vault.certificate(for:endpoint)) }.value
                guard self.generation == token else { connection.cancel();return }
                self.connection=connection
                let info=try await connection.serverInfo()
                guard self.generation == token else { return }
                guard self.recovery.remaining(nowMillis:self.nowMillis()) > 0 else {
                    self.endRecovery("The reconnect window expired. Connect again when the host is reachable.");return
                }
                guard info.paired,info.uniqueID == plan.hostID else {
                    self.endRecovery("The host identity or pairing changed. Connect and pair again.");return
                }
                guard info.currentGame == plan.app.id else {
                    self.endRecovery("The original app is no longer running on the host. Choose an app to start a new stream.");return
                }
                guard let capabilities=self.capabilities else { self.endRecovery("Video capabilities are unavailable.");return }
                self.host=info
                self.launchStream(plan,connection:connection,capabilities:capabilities)
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return }
                if (error as? HostConnectionError)?.retryable == true { self.scheduleRecovery(error.localizedDescription) }
                else { self.endRecovery(error.localizedDescription) }
            }
        }
    }
    private func endRecovery(_ message: String) {
        disconnect();errorMessage=message
    }
    func processMediaSnapshot(_ snapshot: VideoTelemetrySnapshot) {
        videoTelemetry=snapshot
        if snapshot.decoded > 0 { hadVideo=true }
        rates.adapt(snapshot)
    }
    private func fail(_ message: String, token: UUID? = nil) {
        if let token, generation != token { return }
        errorMessage = message; phase = host?.paired == true && !library.apps.isEmpty ? .ready : .failed
        status = "Connection needs attention."; pairingPIN = nil
    }
    private func record(_ message: String, token: UUID) {
        guard generation == token else { return }
        diagnostics.append(message)
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
    }
}
