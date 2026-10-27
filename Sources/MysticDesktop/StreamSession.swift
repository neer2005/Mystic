import Foundation
import MysticKit
import MysticStream
import MysticCore

/// Owns one engine on one worker queue. Interrupt may be called while start blocks;
/// stop/free are serialized after start returns. A fresh instance is used on reconnect.
final class StreamSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mystic.StreamSession")
    private let engine: StreamingEngine
    private let inputMailbox = StreamInputMailbox()
    private var delivery = RemoteInputDelivery()
    private var acceptingInput = false
    private let inputFailure: @Sendable () -> Void
    init(inputFailure: @escaping @Sendable () -> Void = {}) throws {
        engine = try StreamingEngine();self.inputFailure = inputFailure
    }
    func start(host: String, launch: LaunchedStream, configuration: StreamConfiguration,
               decoder: VideoToolboxDecoder, audio: AudioPlayer, event: @escaping @Sendable (EngineEvent) -> Void,
               failure: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                guard let version = launch.appVersion else { throw HostConnectionError("The host did not report its application version.") }
                try engine.start(host: host, appVersion: version, rtspSessionURL: launch.rtspURL,
                    serverCodecModeSupport: launch.codecSupport, configuration: configuration,
                    video: decoder, audio: audio, onEvent: event)
                acceptingInput = true
            } catch { failure(String(describing: error)) }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        inputMailbox.close()
        engine.interrupt()
        queue.async { [self] in
            try? delivery.deliver(.releaseAll, send: performInput)
            acceptingInput = false
            engine.stop(); completion()
        }
    }
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
