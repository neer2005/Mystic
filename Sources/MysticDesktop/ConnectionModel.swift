import AppKit
import Foundation
import Observation
import MysticKit
import MysticStream

@MainActor @Observable
public final class ConnectionModel {
    public enum Phase: String { case idle, connecting, pairing, ready, launching, streaming, disconnecting, failed }
    public var address: String
    public var port: String
    public var selectedAppID: Int32?
    public var resolution = "1920x1080"
    public var fps: UInt32 = 60
    public var bitrateMbps: Int32 = 20
    public var hdr = false
    public var codec = "auto"
    public var audioLayout = "stereo"
    public var volume: Float = 0.8 { didSet { audioPlayer?.setVolume(volume, muted: muted) } }
    public var muted = false { didSet { audioPlayer?.setVolume(volume, muted: muted) } }
    public private(set) var audioStatus = "Audio idle"

    public private(set) var phase: Phase = .idle
    public private(set) var status = "Enter your host’s LAN address to connect."
    public private(set) var errorMessage: String?
    public private(set) var host: HostInfo?
    public private(set) var apps: [HostApp] = []
    public private(set) var pairingPIN: String?
    public private(set) var capabilities: VideoCapabilities?
    public private(set) var presenter: DisplayLayerPresenter?
    public private(set) var diagnostics: [String] = []
    public var selectedApp: HostApp? { apps.first { $0.id == selectedAppID } }
    public var isBusy: Bool { [.connecting, .pairing, .launching, .disconnecting].contains(phase) }
    public var canPlay: Bool { phase == .ready && selectedApp != nil && capabilities != nil }
    public var hasSession: Bool { phase == .streaming || phase == .launching }

    @ObservationIgnored private let rememberHost: Bool
    @ObservationIgnored private let vault: any CredentialsStorage
    @ObservationIgnored private let makeHost: @Sendable (String, UInt16, ClientIdentity, String?) throws -> any HostService
    @ObservationIgnored private var connection: (any HostService)?
    @ObservationIgnored private var session: StreamSession?
    @ObservationIgnored private var decoder: VideoToolboxDecoder?
    @ObservationIgnored private var audioPlayer: AudioPlayer?
    @ObservationIgnored private var audioMonitor: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var endpoint = ""
    @ObservationIgnored private var connectedAddress = ""

    public init(vault: any CredentialsStorage = CredentialsVault(), rememberHost: Bool = true,
                makeHost: @escaping @Sendable (String, UInt16, ClientIdentity, String?) throws -> any HostService = {
                    try HostConnection(address: $0, port: $1, identity: $2, certificate: $3)
                }) {
        self.vault = vault; self.makeHost = makeHost; self.rememberHost = rememberHost
        address = UserDefaults.standard.string(forKey: "lastHost") ?? ""
        port = UserDefaults.standard.string(forKey: "lastPort") ?? "47989"
    }
    public func prepare() async {
        guard capabilities == nil, !probing else { return }
        probing = true
        capabilities = await VideoCapabilities.probe()
        probing = false
    }
    public func connect() {
        guard !isBusy, !hasSession else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains("/"), let port = UInt16(port), port > 0 else {
            fail("Enter a host name or IP address, and an HTTP port from 1 to 65535."); return
        }
        connection?.cancel(); operation?.cancel()
        let token = UUID(); generation = token
        self.endpoint = "\(address.lowercased()):\(port)"
        connectedAddress = address
        let endpoint = self.endpoint, vault = vault, factory = makeHost
        phase = .connecting; status = "Connecting to \(address)…"; errorMessage = nil
        host = nil; apps = []; selectedAppID = nil; pairingPIN = nil; diagnostics = []
        if rememberHost {
            UserDefaults.standard.set(address, forKey: "lastHost")
            UserDefaults.standard.set(String(port), forKey: "lastPort")
        }
        operation = Task { [weak self] in
            do {
                let connection = try await Task.detached {
                    try factory(address, port, vault.identity(), vault.certificate(for: endpoint))
                }.value
                guard let self, self.generation == token else { connection.cancel(); return }
                self.connection = connection
                let info = try await connection.serverInfo()
                guard self.generation == token else { return }
                self.host = info
                if info.paired { try await self.loadApps(connection, token: token) }
                else { self.phase = .ready; self.status = "Pair with \(info.name) to view its apps." }
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
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
        apps = list; selectedAppID = list.first?.id; phase = .ready
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
            options.width = dims[0]; options.height = dims[1]; options.fps = fps; options.hdr = hdr
            var config = StreamConfiguration()
            config.width = Int32(dims[0]); config.height = Int32(dims[1]); config.fps = Int32(fps)
            config.bitrateKbps = bitrateMbps * 1000; config.supportedVideoFormats = mask
            config.colorSpace = hdr ? 2 : 1; config.colorRange = 0
            config.channelCount = options.channelCount; config.channelMask = options.channelMask
            let token = generation
            phase = .launching; status = "Launching \(app.name)…"; errorMessage = nil
            let address = connectedAddress
            operation = Task { [weak self, config] in
                do {
                    let launch = try await connection.launch(options)
                    guard let self, self.generation == token else { return }
                    var config = config
                    config.remoteInputAESKey = launch.key; config.remoteInputAESIV = launch.iv
                    let presenter = DisplayLayerPresenter(onFailure: { [weak self] message in
                        Task { @MainActor in self?.record(message, token: token) }
                    })
                    let decoder = VideoToolboxDecoder(capabilities: capabilities, presenter: presenter, log: { [weak self] message in
                        Task { @MainActor in self?.record(message, token: token) }
                    })
                    let audio = AudioPlayer(log: { [weak self] message in
                        Task { @MainActor in self?.record(message, token: token) }
                    })
                    audio.setVolume(self.volume, muted: self.muted)
                    self.audioPlayer = audio
                    let session = try StreamSession()
                    self.presenter = presenter; self.decoder = decoder; self.session = session
                    self.status = "Starting video connection…"
                    session.start(host: address, launch: launch, configuration: config, decoder: decoder, audio: audio,
                        event: { [weak self] event in Task { @MainActor in self?.handle(event, token: token) } },
                        failure: { [weak self] message in Task { @MainActor in self?.streamFailed(message, token: token) } })
                    self.monitorAudio(audio, token: token)
                } catch { self?.fail(error.localizedDescription, token: token) }
            }
        } catch { fail(error.localizedDescription) }
    }
    public func disconnect() {
        generation = UUID(); let token = generation
        audioMonitor?.cancel(); audioMonitor = nil; audioStatus = "Audio stopped"
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
    private func monitorAudio(_ player: AudioPlayer, token: UUID) {
        audioMonitor?.cancel()
        audioMonitor = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player, self.generation == token else { return }
                let stats = player.statistics
                self.audioStatus = "Audio: \(stats.decodedPackets) packets, \(stats.concealedPackets) concealed, \(stats.renderedFrames) frames played, \(stats.queuedFrames/48) ms queued"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func handle(_ event: EngineEvent, token: UUID) {
        guard generation == token else { return }
        switch event {
        case .connected: phase = .streaming; status = "Streaming \(selectedApp?.name ?? "video")."
        case .stageStarting(let stage): status = "Starting \(stage.name)…"
        case .stageComplete: break
        case .stageFailed(let stage, let code): record("\(stage.name) failed (\(code)).", token: token)
        case .terminated(let code): streamFailed("The host ended the stream (code \(code)).", token: token)
        case .log(let message):
            // Only our wrapper's setup diagnostics are safe here. Protocol logs may contain launch keys.
            if message.hasPrefix("video decoder rejected ") || message.hasPrefix("audio renderer rejected ") { record(message, token: token) }
        }
    }
    private func streamFailed(_ message: String, token: UUID) {
        guard generation == token else { return }
        disconnect()
        errorMessage = message
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
