import CMystic
import Foundation

/// Errors surfaced by the streaming engine, carrying the engine's own message where it has
/// one.
public enum EngineError: Error, Equatable, CustomStringConvertible {
    /// The linked library was built for a different ABI than this Swift layer expects.
    case abiMismatch(linked: UInt32, expected: UInt32)
    case invalidArgument(String)
    /// `start` failed; the message names the stage and code the engine reported.
    case startFailed(String)
    case notStarted
    case inputFailed

    public var description: String {
        switch self {
        case let .abiMismatch(linked, expected):
            return "mystic ABI \(linked) does not match the expected \(expected); rebuild engine/"
        case let .invalidArgument(message):
            return "invalid argument: \(message)"
        case let .startFailed(message):
            return "start failed: \(message)"
        case .notStarted:
            return "no session is running"
        case .inputFailed:
            return "the engine rejected the input event"
        }
    }
}

/// The stream configuration, in Swift terms.
///
/// Values follow the header's defaults for anything not set here. `supportedVideoFormats`
/// and the capability fields use the engine's own bit constants (`VIDEO_FORMAT_*`,
/// `CAPABILITY_*`); they are not redefined here on purpose — one source of truth.
public struct StreamConfiguration: Sendable, Equatable {
    public var width: Int32 = 1920
    public var height: Int32 = 1080
    public var fps: Int32 = 60
    public var bitrateKbps: Int32 = 20000
    public var packetSize: Int32 = 1392
    public var supportedVideoFormats: UInt32 = 1 // H.264 until the decoder says otherwise
    public var videoCapabilities: UInt32 = 0
    public var audioCapabilities: UInt32 = 0
    public var encryptionFlags: UInt32 = 0
    /// Launch credentials. Both are exactly 16 bytes and must match the host's launch request.
    public var remoteInputAESKey: [UInt8] = Array(repeating: 0, count: 16)
    public var remoteInputAESIV: [UInt8] = Array(repeating: 0, count: 16)
    public var colorSpace: Int32 = 1
    public var colorRange: Int32 = 1
    public var clientRefreshRateX100: Int32 = 0
    public var channelCount: UInt8 = 2
    public var channelMask: UInt16 = 0x3
    public var microphone = false
    public var hapticsPCM = false

    public init() {}
}

/// Stage numbers the engine reports, mirroring `MysticCallbacks::stage`.
public enum Stage: Int32, Sendable, CaseIterable {
    case platformInit = 1
    case nameResolution = 2
    case audioStreamInit = 3
    case rtspHandshake = 4
    case controlStreamInit = 5
    case videoStreamInit = 6
    case inputStreamInit = 7
    case controlStreamStart = 8
    case videoStreamStart = 9
    case audioStreamStart = 10
    case inputStreamStart = 11

    public var name: String {
        switch self {
        case .platformInit: "platform init"
        case .nameResolution: "name resolution"
        case .audioStreamInit: "audio stream init"
        case .rtspHandshake: "RTSP handshake"
        case .controlStreamInit: "control stream init"
        case .videoStreamInit: "video stream init"
        case .inputStreamInit: "input stream init"
        case .controlStreamStart: "control stream start"
        case .videoStreamStart: "video stream start"
        case .audioStreamStart: "audio stream start"
        case .inputStreamStart: "input stream start"
        }
    }
}

/// What the engine reports as it connects.
public enum EngineEvent: Sendable, Equatable {
    case stageStarting(Stage)
    case stageComplete(Stage)
    case stageFailed(Stage, code: Int32)
    case connected
    case terminated(code: Int32)
    case log(String)
}

/// Owns one engine session.
///
/// `start` blocks until the stream is running or a stage fails, so call it from a
/// background task — never from the main actor. Input calls are cheap and non-blocking.
///
/// The type is not `Sendable`: keep one instance per task and hand events out through
/// ``start(host:configuration:onEvent:)``.
public final class StreamingEngine {
    /// The ABI this Swift layer was written against.
    public static let expectedABI: UInt32 = 2

    private var handle: OpaquePointer?
    private let eventLock = NSLock()
    private var eventSink: (@Sendable (EngineEvent) -> Void)?
    /// Sinks are set before `start` and read from engine threads afterwards; they are never
    /// reassigned while a session runs.
    private(set) var videoConsumer: VideoConsumer?
    private(set) var audioConsumer: AudioConsumer?

    /// Creates a handle. Fails only if the linked library was built for another ABI.
    public init() throws {
        let linked = mystic_abi_version()
        guard linked == Self.expectedABI else {
            throw EngineError.abiMismatch(linked: linked, expected: Self.expectedABI)
        }
        guard let handle = mystic_session_new() else {
            throw EngineError.invalidArgument("the engine refused to allocate a session")
        }
        self.handle = handle
    }

    /// Serialized on the same worker as start/stop and input.
    public func beginAdaptiveBitrate(ceiling: UInt32, current: UInt32, nowMillis: UInt64) -> Bool {
        mystic_session_bitrate_begin(handle,ceiling,current,nowMillis) == 0
    }
    public func suggestedBitrate(decodeMillis: Float, nowMillis: UInt64) -> UInt32? {
        let kbps=mystic_session_bitrate_sample(handle,decodeMillis,nowMillis)
        return kbps == 0 ? nil : kbps
    }
    public func appliedBitrate(requested: UInt32, applied: UInt32, nowMillis: UInt64) {
        mystic_session_bitrate_applied(handle,requested,applied,nowMillis)
    }

    deinit {
        if let handle {
            // Stop first: free() must not race with a running callback.
            _ = mystic_session_stop(handle)
            mystic_session_free(handle)
        }
    }

    /// Connects to `host` and blocks until the stream runs or a stage fails.
    ///
    /// - Parameter onEvent: called from engine threads; must be safe to call concurrently
    ///   and must not assume the main thread.
    public func start(
        host: String,
        appVersion: String,
        rtspSessionURL: String? = nil,
        serverCodecModeSupport: UInt32 = 1,
        configuration: StreamConfiguration = .init(),
        video: VideoConsumer? = nil,
        audio: AudioConsumer? = nil,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) throws {
        guard let handle else { throw EngineError.notStarted }

        videoConsumer = video
        audioConsumer = audio

        eventLock.lock()
        eventSink = onEvent
        eventLock.unlock()

        var config = try configuration.cConfiguration()

        var callbacks = MysticCallbacks()
        // The user pointer carries this instance so the C callbacks can find the sink. The
        // engine only hands it back; it never dereferences it.
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.stage = { user, stage, event, error in
            guard let user else { return }
            let engine = Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
            guard let kind = Stage(rawValue: stage) else { return }
            let mapped: EngineEvent
            switch event {
            case MYSTIC_STAGE_STARTING: mapped = .stageStarting(kind)
            case MYSTIC_STAGE_COMPLETE: mapped = .stageComplete(kind)
            case MYSTIC_STAGE_FAILED: mapped = .stageFailed(kind, code: error)
            default: return
            }
            engine.emit(mapped)
        }
        callbacks.connection_started = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue().emit(.connected)
        }
        callbacks.connection_terminated = { user, code in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .emit(.terminated(code: code))
        }
        callbacks.log = { user, message in
            guard let user, let message else { return }
            let text = String(cString: message)
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue().emit(.log(text))
        }

        callbacks.video_setup = { user, setup in
            guard let user, let setup else { return 0 }
            let engine = Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
            guard let consumer = engine.videoConsumer else { return 0 }
            let info = VideoSetupInfo(setup.pointee)
            do {
                try consumer.setup(info)
                return 0
            } catch {
                // Failing here aborts the connection with a reason, which beats a black window.
                engine.emit(.log("video decoder rejected \(info.width)x\(info.height): \(error)"))
                return 1
            }
        }

        callbacks.video_start = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .videoConsumer?.start()
        }

        callbacks.video_submit = { user, frame in
            guard let user, let frame else { return 0 }
            let engine = Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
            guard let consumer = engine.videoConsumer, frame.pointee.data != nil else { return 0 }
            // The frame borrows engine memory; it must be consumed before this returns.
            return consumer.submit(VideoFrameInfo(frame.pointee)).callbackCode
        }

        callbacks.video_stop = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .videoConsumer?.stop()
        }

        callbacks.video_cleanup = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .videoConsumer?.cleanup()
        }

        callbacks.audio_init = { user, setup in
            guard let user, let setup else { return 0 }
            let engine = Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
            guard let consumer = engine.audioConsumer else { return 0 }
            let info = AudioSetupInfo(setup.pointee)
            do {
                try consumer.setup(info)
                return 0
            } catch {
                engine.emit(.log("audio renderer rejected the stream: \(error)"))
                return 1
            }
        }

        callbacks.audio_start = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .audioConsumer?.start()
        }

        callbacks.audio_play = { user, packet, length in
            guard let user else { return }
            let consumer = Unmanaged<StreamingEngine>.fromOpaque(user)
                .takeUnretainedValue().audioConsumer
            // A null packet (or zero length) means "lost": conceal rather than decode.
            guard let packet, length > 0 else {
                consumer?.play(nil)
                return
            }
            consumer?.play(UnsafeRawBufferPointer(start: packet, count: length))
        }

        callbacks.audio_stop = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .audioConsumer?.stop()
        }

        callbacks.audio_cleanup = { user in
            guard let user else { return }
            Unmanaged<StreamingEngine>.fromOpaque(user).takeUnretainedValue()
                .audioConsumer?.cleanup()
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        let code = mystic_session_start(
            handle,
            host,
            appVersion,
            rtspSessionURL,
            serverCodecModeSupport,
            &config,
            &callbacks,
            &errorBuffer,
            errorBuffer.count
        )

        guard code == MYSTIC_OK else {
            let bytes = errorBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let message = String(decoding: bytes, as: UTF8.self)
            switch code {
            case MYSTIC_ERR_START_FAILED:
                throw EngineError.startFailed(message)
            default:
                throw EngineError.invalidArgument(message)
            }
        }
    }

    /// Stops every stream. Safe to call more than once.
    public func stop() {
        guard let handle else { return }
        _ = mystic_session_stop(handle)
    }

    /// Cancels a `start` that is still blocking. Safe from any thread.
    public func interrupt() {
        guard let handle else { return }
        mystic_session_interrupt(handle)
    }

    // MARK: - Input

    public func mouseMove(dx: Int16, dy: Int16) throws {
        try check(mystic_session_mouse_move(requireHandle(), dx, dy))
    }

    public func mousePosition(x: Int16, y: Int16, width: Int16, height: Int16) throws {
        try check(mystic_session_mouse_position(requireHandle(), x, y, width, height))
    }

    public func mouseButton(_ button: UInt8, down: Bool) throws {
        try check(mystic_session_mouse_button(requireHandle(), button, down))
    }

    public func keyboard(keyCode: UInt16, down: Bool, modifiers: UInt8, flags: UInt8) throws {
        try check(mystic_session_keyboard(requireHandle(), keyCode, down, modifiers, flags))
    }

    public func scroll(clicks: Int8) throws {
        try check(mystic_session_scroll(requireHandle(), clicks))
    }

    public func scrollHighResolution(amount: Int16) throws {
        try check(mystic_session_high_res_scroll(requireHandle(), amount))
    }

    public func scrollHorizontal(amount: Int16) throws {
        try check(mystic_session_horizontal_scroll(requireHandle(), amount))
    }

    public func controller(slot: UInt8, activeMask: UInt16, buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8,
                           leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16) throws {
        try check(mystic_session_controller(requireHandle(),slot,activeMask,buttons,leftTrigger,rightTrigger,leftX,leftY,rightX,rightY))
    }
    public func controllerArrival(slot: UInt8, activeMask: UInt16) throws {
        try check(mystic_session_controller_arrival(requireHandle(),slot,activeMask))
    }

    public var microphoneAvailable: Bool { mystic_session_microphone_available(requireHandle()) }
    public func sendMicrophone(_ packet: UnsafeRawBufferPointer) throws {
        try check(mystic_session_send_microphone(requireHandle(),packet.bindMemory(to:UInt8.self).baseAddress,packet.count))
    }

    public func requestIDR() throws {
        try check(mystic_session_request_idr(requireHandle()))
    }

    // MARK: - Internals

    private func requireHandle() -> OpaquePointer {
        guard let handle else { throwEngineError(.notStarted) }
        return handle
    }

    /// `requireHandle` cannot throw from a non-throwing context, so it traps instead: a
    /// handle is only nil after a failed init, which throws before this is reachable.
    private func throwEngineError(_ error: EngineError) -> Never {
        // Reaching here means the invariant above was broken by a refactor; failing loudly
        // in development beats sending input to a freed session.
        preconditionFailure("StreamingEngine used after the handle was released: \(error)")
    }

    private func check(_ code: Int32) throws {
        switch code {
        case MYSTIC_OK: return
        case MYSTIC_ERR_NOT_STARTED: throw EngineError.notStarted
        case MYSTIC_ERR_INPUT_FAILED: throw EngineError.inputFailed
        default: throw EngineError.invalidArgument("engine returned \(code)")
        }
    }

    private func emit(_ event: EngineEvent) {
        eventLock.lock()
        let sink = eventSink
        eventLock.unlock()
        sink?(event)
    }
}

private extension NSLock {
}


extension StreamConfiguration {
    func cConfiguration() throws -> MysticStreamConfig {
        guard self.remoteInputAESKey.count == 16, self.remoteInputAESIV.count == 16 else {
            throw EngineError.invalidArgument("launch AES key and IV must each contain 16 bytes")
        }
        var config = MysticStreamConfig()
        config.encryption_flags = self.encryptionFlags
        withUnsafeMutableBytes(of: &config.remote_input_aes_key) { $0.copyBytes(from: self.remoteInputAESKey) }
        withUnsafeMutableBytes(of: &config.remote_input_aes_iv) { $0.copyBytes(from: self.remoteInputAESIV) }
        config.width = self.width
        config.height = self.height
        config.fps = self.fps
        config.bitrate_kbps = self.bitrateKbps
        config.packet_size = self.packetSize
        config.supported_video_formats = self.supportedVideoFormats
        config.video_capabilities = self.videoCapabilities
        config.audio_capabilities = self.audioCapabilities
        config.color_space = self.colorSpace
        config.color_range = self.colorRange
        config.client_refresh_rate_x100 = self.clientRefreshRateX100
        config.channel_count = self.channelCount
        config.channel_mask = self.channelMask
        config.microphone = self.microphone
        config.haptics_pcm = self.hapticsPCM

        return config
    }
}
