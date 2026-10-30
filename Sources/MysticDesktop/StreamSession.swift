import Foundation
import MysticKit
import MysticStream
import MysticCore

struct StreamStartFailure: Sendable {
    let message: String
    let stage: Stage?
    let code: Int32?
    var retryable: Bool {
        guard let stage,let code else { return false }
        return StreamRecovery.recoversStartup(stage:stage,code:code)
    }
}
private final class StartupFailureRecord: @unchecked Sendable {
    private let lock=NSLock()
    private var failedStage: (Stage,Int32)?
    func receive(_ event: EngineEvent) {
        if case let .stageFailed(stage,code)=event { lock.withLock { failedStage=(stage,code) } }
    }
    func failure(_ error: any Error) -> StreamStartFailure {
        let value=lock.withLock { failedStage }
        return StreamStartFailure(message:String(describing:error),stage:value?.0,code:value?.1)
    }
}

protocol StreamSessionService: AnyObject, Sendable {
    func start(host: String, launch: LaunchedStream, configuration: StreamConfiguration,
               decoder: VideoToolboxDecoder, audio: AudioPlayer, event: @escaping @Sendable (EngineEvent) -> Void,
               failure: @escaping @Sendable (StreamStartFailure) -> Void,
               microphoneMuted: Bool, microphoneStatus: @escaping @Sendable (String) -> Void)
    func stop(completion: @escaping @Sendable () -> Void)
    func takeControllerFeedback() async -> [ControllerFeedback]
    func requestVideoRecovery()
    func setMicrophoneMuted(_ muted: Bool)
    func send(_ event: RemoteInputEvent) -> Bool
    func beginAdaptiveBitrate(ceiling: UInt32, current: UInt32) async -> Bool
    func suggestedBitrate(decodeMillis: Float) async -> UInt32?
    func appliedBitrate(requested: UInt32, applied: UInt32) async
}

/// Owns one engine on one worker queue. Interrupt may be called while start blocks;
/// stop/free are serialized after start returns. A fresh instance is used on reconnect.
final class StreamSession: StreamSessionService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mystic.StreamSession")
    private let engine: StreamingEngine
    private let recoveryRequests = KeyframeRequestGate()
    private let inputMailbox = StreamInputMailbox()
    private var delivery = RemoteInputDelivery()
    private var acceptingInput = false
    private var microphone: MicrophoneCapture?
    private let recoveryFailure: @Sendable (String) -> Void
    private let inputFailure: @Sendable () -> Void
    init(inputFailure: @escaping @Sendable () -> Void = {},recoveryFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        engine = try StreamingEngine();self.inputFailure = inputFailure;self.recoveryFailure=recoveryFailure
    }
    func start(host: String, launch: LaunchedStream, configuration: StreamConfiguration,
               decoder: VideoToolboxDecoder, audio: AudioPlayer, event: @escaping @Sendable (EngineEvent) -> Void,
               failure: @escaping @Sendable (StreamStartFailure) -> Void,
               microphoneMuted: Bool = false,microphoneStatus: @escaping @Sendable (String) -> Void = { _ in }) {
        queue.async { [self] in
            let startup=StartupFailureRecord()
            do {
                guard let version = launch.appVersion else { throw HostConnectionError("The host did not report its application version.") }
                try engine.start(host: host, appVersion: version, rtspSessionURL: launch.rtspURL,
                    serverCodecModeSupport: launch.codecSupport, configuration: configuration,
                    video: decoder, audio: audio, onEvent: { value in startup.receive(value);event(value) })
                acceptingInput = true
                if configuration.microphone {
                    if engine.microphoneAvailable {
                        let capture=MicrophoneCapture(queue:queue,send:{ [weak self] packet in
                            guard let self,self.acceptingInput else { throw HostConnectionError("Stream ended.") }
                            try self.engine.sendMicrophone(packet)
                        },report:microphoneStatus)
                        do { try capture.start();capture.setMuted(microphoneMuted);microphone=capture }
                        catch { microphoneStatus("Microphone unavailable: \(error.localizedDescription)") }
                    } else { microphoneStatus("Host did not negotiate encrypted microphone passthrough.") }
                } else { microphoneStatus("Microphone off") }
            } catch { failure(startup.failure(error)) }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        inputMailbox.close();recoveryRequests.close()
        engine.interrupt()
        queue.async { [self] in
            microphone?.stop();microphone=nil
            try? delivery.deliver(.releaseAll, send: performInput)
            acceptingInput = false
            engine.stop(); completion()
        }
    }
    func beginAdaptiveBitrate(ceiling: UInt32, current: UInt32) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput && engine.beginAdaptiveBitrate(ceiling:ceiling,current:current,nowMillis:Self.nowMillis()))
        } }
    }
    func suggestedBitrate(decodeMillis: Float) async -> UInt32? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.suggestedBitrate(decodeMillis:decodeMillis,nowMillis:Self.nowMillis()) : nil)
        } }
    }
    func appliedBitrate(requested: UInt32, applied: UInt32) async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if acceptingInput { engine.appliedBitrate(requested:requested,applied:applied,nowMillis:Self.nowMillis()) }
            continuation.resume()
        } }
    }
    func takeControllerFeedback() async -> [ControllerFeedback] {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.takeControllerFeedback() : [])
        } }
    }
    private static func nowMillis() -> UInt64 { DispatchTime.now().uptimeNanoseconds/1_000_000 }
    /// May be called from a decoder callback, including while start is still returning.
    func requestVideoRecovery() {
        guard recoveryRequests.offer() else { return }
        queue.async { [self] in
            defer { recoveryRequests.finish() }
            guard recoveryRequests.isOpen,acceptingInput else { return }
            do { try engine.requestIDR() } catch { recoveryFailure("Keyframe request failed: \(error.localizedDescription)") }
        }
    }
    func setMicrophoneMuted(_ muted: Bool) { queue.async { [self] in microphone?.setMuted(muted) } }
    @discardableResult
    func send(_ event: RemoteInputEvent) -> Bool {
        let result = inputMailbox.offer(event)
        if result.schedule { queue.async { [self] in drainInput() } }
        return result.accepted
    }
    private func drainInput() {
        let batch = inputMailbox.take()
        if acceptingInput {
            for event in batch.events {
                guard inputMailbox.isCurrent(batch.epoch) else { break }
                do { try delivery.deliver(event, send: performInput) }
                catch {
                    inputMailbox.close();acceptingInput = false
                    try? delivery.deliver(.releaseAll, send: performInput)
                    inputFailure()
                    break
                }
            }
        }
        if inputMailbox.finish() { queue.async { [self] in drainInput() } }
    }
    private func performInput(_ event: RemoteInputEvent) throws {
        switch event {
        case let .key(code,down,modifiers,flags): try engine.keyboard(keyCode:code,down:down,modifiers:modifiers,flags:flags)
        case let .button(number,down): try engine.mouseButton(number,down:down)
        case let .position(x,y,width,height): try engine.mousePosition(x:x,y:y,width:width,height:height)
        case let .motion(dx,dy): try engine.mouseMove(dx:dx,dy:dy)
        case let .scroll(vertical,horizontal):
            if vertical != 0 { try engine.scrollHighResolution(amount:vertical) }
            if horizontal != 0 { try engine.scrollHorizontal(amount:horizontal) }
        case let .controller(slot,mask,s):
            try engine.controller(slot:slot,activeMask:mask,buttons:s.buttons,leftTrigger:s.leftTrigger,rightTrigger:s.rightTrigger,
                                  leftX:s.leftX,leftY:s.leftY,rightX:s.rightX,rightY:s.rightY)
        case let .controllerArrival(slot,mask,capabilities,epoch): try engine.controllerArrival(slot:slot,activeMask:mask,capabilities:capabilities,feedbackEpoch:epoch)
        case .releaseAll: break
        }
    }

}

/// One scheduled drain at a time, with bounded coalescing storage.
final class StreamInputMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events = RemoteInputQueue()
    private var scheduled = false
    private var dirty = false
    private var closed = false
    private var epoch: UInt64 = 0
    func offer(_ event: RemoteInputEvent) -> (schedule:Bool,accepted:Bool) {
        lock.lock();defer { lock.unlock() }
        guard !closed else { return (false,false) }
        let accepted = events.append(event)
        if event == .releaseAll || !accepted { epoch &+= 1 }
        dirty = true
        guard !scheduled else { return (false,accepted) }
        scheduled = true;return (true,accepted)
    }
    func take() -> (events:[RemoteInputEvent],epoch:UInt64) {
        lock.lock();defer { lock.unlock() }
        dirty = false;return (events.take(),epoch)
    }
    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock();defer { lock.unlock() };return !closed && value == epoch
    }
    func finish() -> Bool {
        lock.lock();defer { lock.unlock() }
        if dirty && !closed { return true }
        scheduled = false;return false
    }
    func close() {
        lock.lock();defer { lock.unlock() }
        closed = true;epoch &+= 1;_ = events.take();dirty = false
    }
}

/// Bound asynchronous recovery requests to one queued engine operation. Closing
/// invalidates already queued work before session stop/free.
final class KeyframeRequestGate: @unchecked Sendable {
    private let lock=NSLock()
    private var pending=false,closed=false
    func offer() -> Bool {
        lock.lock();defer { lock.unlock() }
        guard !closed,!pending else { return false };pending=true;return true
    }
    var isOpen: Bool { lock.lock();defer { lock.unlock() };return !closed }
    func finish() { lock.lock();defer { lock.unlock() };pending=false }
    func close() { lock.lock();defer { lock.unlock() };closed=true }
}
