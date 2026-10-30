import AVFoundation
import GameController
import AppKit
import Foundation
import Observation
import MysticKit
import MysticStream
import MysticCore

@MainActor @Observable
public final class ConnectionModel {
    public enum Phase: String { case idle, connecting, pairing, ready, launching, streaming, reconnecting, disconnecting, failed }
    public var address: String
    public var port: String
    public let savedHosts: SavedHosts
    public let discovery: HostDiscovery
    public var selectedAppID: Int32?
    public let settings: AppSettings
    public var resolution: String {
        get { settings.value.resolution }
        set { settings.update { $0.resolution=newValue } }
    }
    public var fps: UInt32 {
        get { settings.value.fps }
        set { settings.update { $0.fps=newValue } }
    }
    public var bitrateMbps: Int32 {
        get { settings.value.bitrateMbps }
        set { settings.update { $0.bitrateMbps=newValue } }
    }
    public var hdr: Bool {
        get { settings.value.hdr }
        set { settings.update { $0.hdr=newValue } }
    }
    public var codec: String {
        get { settings.value.codec }
        set { settings.update { $0.codec=newValue } }
    }
    public var audioLayout: String {
        get { settings.value.audioLayout }
        set { settings.update { $0.audioLayout=newValue } }
    }
    public var volume: Float {
        get { settings.value.volume }
        set { settings.update { $0.volume=newValue };audioPlayer?.setVolume(volume,muted:muted) }
    }
    public var muted: Bool {
        get { settings.value.muted }
        set { settings.update { $0.muted=newValue };audioPlayer?.setVolume(volume,muted:muted) }
    }
    public var showLatencyHUD: Bool {
        get { settings.value.showLatencyHUD }
        set { settings.update { $0.showLatencyHUD=newValue } }
    }
    public var microphoneEnabled: Bool {
        get { settings.value.microphoneEnabled ?? false }
        set { settings.update { $0.microphoneEnabled=newValue } }
    }
    public var microphoneMuted=false { didSet { session?.setMicrophoneMuted(microphoneMuted) } }
    public var automaticReconnect: Bool {
        get { settings.value.automaticReconnect ?? true }
        set { settings.update { $0.automaticReconnect=newValue } }
    }
    public var adaptiveBitrate: Bool {
        get { settings.value.adaptiveBitrate ?? false }
        set { settings.update { $0.adaptiveBitrate=newValue } }
    }
    public private(set) var microphoneStatus="Microphone off"
    public private(set) var audioStatus = "Audio idle"

    public private(set) var phase: Phase = .idle
    public private(set) var status = "Enter your host’s LAN address to connect."
    public private(set) var errorMessage: String?
    public private(set) var host: HostInfo?
    public private(set) var apps: [HostApp] = []
    public private(set) var pairingPIN: String?
    public private(set) var capabilities: VideoCapabilities?
    public private(set) var presenter: DisplayLayerPresenter?
    public private(set) var inputCapture: StreamInputCapture?
    public private(set) var videoTelemetry: VideoTelemetrySnapshot?
    public private(set) var diagnostics: [String] = []
    public var libraryQuery = "" { didSet { reconcileLibrarySelection() } }
    public var libraryHDROnly = false { didSet { reconcileLibrarySelection() } }
    public var filteredApps: [HostApp] {
        let query=libraryQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        let filtered=apps.filter { (!libraryHDROnly || $0.hdrSupported) && (query.isEmpty || $0.name.localizedStandardContains(query)) }
        return settings.value.librarySort == "host" ? filtered : filtered.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func reconcileLibrarySelection() {
        if let selectedAppID,!filteredApps.contains(where: { $0.id == selectedAppID }) { self.selectedAppID=filteredApps.first?.id }
    }
    public var selectedHostEndpointID: String? { host != nil || isBusy || hasSession ? endpoint : nil }
    public func selectHost(_ id: String?) {
        guard let id else { return }
        if let endpoint=savedHosts.hosts.first(where: { $0.id == id })?.endpoint ?? discovery.hosts.first(where: { $0.id == id })?.endpoint {
            if id != selectedHostEndpointID { connect(to:endpoint) }
        }
    }
    public var selectedApp: HostApp? { apps.first { $0.id == selectedAppID } }
    public var isBusy: Bool { [.connecting, .pairing, .launching, .reconnecting, .disconnecting].contains(phase) }
    public var canPlay: Bool { phase == .ready && selectedApp != nil && capabilities != nil }
    public var hasSession: Bool { phase == .streaming || phase == .launching || phase == .reconnecting }

    @ObservationIgnored private let microphonePermission: @Sendable () async -> Bool
    @ObservationIgnored private let rememberHost: Bool
    @ObservationIgnored private let vault: any CredentialsStorage
    @ObservationIgnored private let makeHost: @Sendable (String, UInt16, ClientIdentity, String?) throws -> any HostService
    @ObservationIgnored private var connection: (any HostService)?
    @ObservationIgnored private var session: (any StreamSessionService)?
    @ObservationIgnored private var decoder: VideoToolboxDecoder?
    @ObservationIgnored private var audioPlayer: AudioPlayer?
    @ObservationIgnored private var telemetry: VideoTelemetry?
    @ObservationIgnored private var statisticsMonitor: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
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
    }
    @ObservationIgnored private var plan: StreamPlan?
    @ObservationIgnored private var recovery = StreamRecovery()
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var hadVideo = false
    @ObservationIgnored private var connectedAt: UInt64?
    @ObservationIgnored private var bitrateTask: Task<Void, Never>?
    @ObservationIgnored private var adaptationActive = false
    @ObservationIgnored private var adaptationInitialized = false
    @ObservationIgnored private var lastDecoded: UInt64 = 0
    @ObservationIgnored var makeSession: (@escaping @Sendable () -> Void, @escaping @Sendable (String) -> Void) throws -> any StreamSessionService = {
        try StreamSession(inputFailure:$0,recoveryFailure:$1)
    }
    @ObservationIgnored var sleepForRecovery: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(for:.milliseconds($0)) }
    @ObservationIgnored var nowMillis: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds/1_000_000 }
    public private(set) var bitrateStatus = "Fixed bitrate"

    public init(vault: any CredentialsStorage = CredentialsVault(), rememberHost: Bool = true,
                microphonePermission: @escaping @Sendable () async -> Bool = {
                    switch AVCaptureDevice.authorizationStatus(for:.audio) {
                    case .authorized: return true
                    case .notDetermined: return await AVCaptureDevice.requestAccess(for:.audio)
                    default:return false
                    }
                },preferences: (any HostPreferencesStorage)? = HostPreferences(),settings: AppSettings? = nil,discovery: HostDiscovery = HostDiscovery(),
                makeHost: @escaping @Sendable (String, UInt16, ClientIdentity, String?) throws -> any HostService = {
                    try HostConnection(address: $0, port: $1, identity: $2, certificate: $3)
                }) {
        self.microphonePermission=microphonePermission
        self.settings=settings ?? AppSettings(storage:rememberHost ? SettingsPreferences() : nil)
        self.savedHosts=SavedHosts(storage:rememberHost ? preferences : nil);self.discovery=discovery
        self.vault = vault; self.makeHost = makeHost; self.rememberHost = rememberHost
        address = savedHosts.hosts.first?.endpoint.address ?? UserDefaults.standard.string(forKey: "lastHost") ?? ""
        port = savedHosts.hosts.first.map { String($0.endpoint.port) } ?? UserDefaults.standard.string(forKey: "lastPort") ?? "47989"
    }
    public func libraryAppeared() { libraryVisible=true;applyLiveSettings() }
    public func libraryDisappeared() { libraryVisible=false;discovery.stop() }
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
        host = nil; apps = []; selectedAppID = nil; pairingPIN = nil; diagnostics = []
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
        let list = try await connection.apps()
        guard generation == token else { return }
        if let host { rememberConnectedHost(host) }
        apps = list; selectedAppID = filteredApps.first?.id; phase = .ready
        status = list.isEmpty ? "The host has no streamable apps configured." : "Connected to \(host?.name ?? address)."
    }
    public func play() {
        guard canPlay, let connection, let app = selectedApp, let capabilities else { return }
        do {
            let dims = resolution.split(separator: "x").compactMap { UInt32($0) }
            guard dims.count == 2 else { throw HostConnectionError("Invalid stream resolution.") }
            var mask: UInt32 = capabilities.supportedFormats
            switch codec {
            case "h264": mask &= 0xF
            case "hevc": mask &= 0xF00
            case "av1": mask &= 0xF000
            default: break
            }
            mask &= hdr ? 0xAA00 : ~UInt32(0xAA00)
            guard mask != 0 else { throw HostConnectionError("This Mac has no verified hardware decoder for the selected codec and HDR mode.") }
            guard !hdr || app.hdrSupported else { throw HostConnectionError("This app does not advertise HDR support.") }
            var options = LaunchOptions(app: app)
            switch audioLayout {
            case "5.1": options.channelCount = 6; options.channelMask = 0x3F
            case "7.1": options.channelCount = 8; options.channelMask = 0x63F
            default: break
            }
            options.gamepadMask = UInt16((1 << min(4,GCController.controllers().filter { $0.extendedGamepad != nil }.count))-1)
            options.width = dims[0]; options.height = dims[1]; options.fps = fps; options.hdr = hdr
            var config = StreamConfiguration()
            config.width = Int32(dims[0]); config.height = Int32(dims[1]); config.fps = Int32(fps)
            config.bitrateKbps = bitrateMbps * 1000; config.supportedVideoFormats = mask
            config.colorSpace = hdr ? 2 : 1; config.colorRange = 0
            config.microphone = microphoneEnabled
            config.channelCount = options.channelCount; config.channelMask = options.channelMask
            recovery = StreamRecovery();recovering = false;hadVideo = false;connectedAt = nil
            let plan = StreamPlan(app:app,options:options,configuration:config,
                adaptive:settings.value.adaptiveBitrate ?? false,reconnect:settings.value.automaticReconnect ?? true,
                hostID:host?.uniqueID ?? "")
            self.plan = plan
            launchStream(plan,connection:connection,capabilities:capabilities)
        } catch { fail(error.localizedDescription) }
    }
    private func launchStream(_ plan: StreamPlan, connection: any HostService, capabilities: VideoCapabilities) {
        let app = plan.app, config = plan.configuration
        var options = plan.options
        options.resumeOnly = recovering
        let token = generation
        lastDecoded=0;adaptationInitialized=false
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
                let presenter = DisplayLayerPresenter(telemetry:telemetry,onFailure: { [weak self] message in
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
                self.adaptationActive = adaptive && launch.runtimeBitrate == true
                self.bitrateStatus = !adaptive ? "Fixed bitrate: \(config.bitrateKbps/1000) Mbps" :
                    (launch.runtimeBitrate == true ? "Automatic bitrate: waiting for video…" : "Automatic bitrate unavailable on this host; using fixed bitrate.")
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
        plan=nil;recovering=false;hadVideo=false;connectedAt=nil;recovery=StreamRecovery()
        bitrateTask?.cancel();bitrateTask=nil;adaptationActive=false;bitrateStatus="Fixed bitrate"
        inputCapture?.setAvailable(false);inputCapture = nil
        generation = UUID(); let token = generation
        microphoneStatus="Microphone off"
        telemetry = nil; videoTelemetry = nil
        statisticsMonitor?.cancel(); statisticsMonitor = nil; audioStatus = "Audio stopped"
        operation?.cancel(); connection?.cancel(); connection = nil; pairingPIN = nil
        host = nil; apps = []; selectedAppID = nil
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

                let stats = player.statistics
                self.audioStatus = "Audio: \(stats.decodedPackets) packets, \(stats.concealedPackets) concealed, \(stats.renderedFrames) frames played, \(stats.queuedFrames/48) ms queued"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func handle(_ event: EngineEvent, token: UUID) {
        guard generation == token else { return }
        switch event {
        case .connected:
            connectedAt=nowMillis();inputCapture?.setAvailable(true);phase = .streaming
            status = "Streaming \(plan?.app.name ?? selectedApp?.name ?? "video")."
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
        recovering=true;phase = .reconnecting;errorMessage=nil
        status="Connection interrupted. Reconnecting in \(delay/1000) seconds…"
        generation=UUID();let token=generation
        operation?.cancel();connection?.cancel();connection=nil
        inputCapture?.setAvailable(false);inputCapture=nil
        statisticsMonitor?.cancel();statisticsMonitor=nil
        bitrateTask?.cancel();bitrateTask=nil;adaptationActive=false
        let previous=session;session=nil
        decoder=nil;presenter=nil;audioPlayer=nil;telemetry=nil;videoTelemetry=nil;lastDecoded=0
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
        let token=generation
        let decoded=snapshot.decoded > lastDecoded
        lastDecoded=snapshot.decoded
        guard phase == .streaming,adaptationActive,bitrateTask == nil,let session,let connection,let plan else { return }
        let decode=decoded ? snapshot.timings[.decode].map { Float($0.p95Micros)/1000 } : nil
        bitrateTask=Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.bitrateTask=nil } }
            do {
                // The first tick establishes the actual host rate before making policy decisions.
                if !self.adaptationInitialized {
                    guard decoded else { return }
                    let ceiling=UInt32(plan.configuration.bitrateKbps)
                    let applied=try await connection.setBitrate(kbps:ceiling)
                    guard self.generation == token,!Task.isCancelled else { return }
                    guard applied > 0,applied <= ceiling,await session.beginAdaptiveBitrate(ceiling:ceiling,current:applied) else {
                        throw HostConnectionError("The host could not start automatic bitrate within the selected limit.")
                    }
                    guard self.generation == token,!Task.isCancelled else { return }
                    self.adaptationInitialized=true
                    self.bitrateStatus="Automatic bitrate: \(applied/1000) Mbps"
                    return
                }
                guard let requested=await session.suggestedBitrate(decodeMillis:decode ?? -1) else { return }
                guard self.generation == token,!Task.isCancelled else { return }
                let applied=try await connection.setBitrate(kbps:requested)
                guard self.generation == token,!Task.isCancelled else { return }
                guard applied > 0,applied <= UInt32(plan.configuration.bitrateKbps) else {
                    throw HostConnectionError("The host returned a bitrate outside the selected limit.")
                }
                await session.appliedBitrate(requested:requested,applied:applied)
                guard self.generation == token else { return }
                self.bitrateStatus="Automatic bitrate: \(applied/1000) Mbps"
            } catch {
                guard self.generation == token else { return }
                self.adaptationActive=false
                self.bitrateStatus="Automatic bitrate stopped: \(error.localizedDescription)"
            }
        }
    }
    private func fail(_ message: String, token: UUID? = nil) {
        if let token, generation != token { return }
        errorMessage = message; phase = host?.paired == true && !apps.isEmpty ? .ready : .failed
        status = "Connection needs attention."; pairingPIN = nil
    }
    private func record(_ message: String, token: UUID) {
        guard generation == token else { return }
        diagnostics.append(message)
        if diagnostics.count > 40 { diagnostics.removeFirst(diagnostics.count - 40) }
    }
}
