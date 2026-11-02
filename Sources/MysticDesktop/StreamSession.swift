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
    func clipboardStep(active: Bool,baseline: Bool,text: String?) async throws -> ClipboardSyncResult
    func liveRates(kbps: UInt32,fpsMilliHz: UInt32) async throws -> LiveRates
    func takeControllerFeedback() async -> [ControllerFeedback]
    /// Reports the keyboard layout; false when the host does not take reports.
    func reportKeyboardLayout(_ layout: KeyboardLayoutReport) async -> Bool
    /// Asks for text field notices; false when the host sends none.
    func requestTextFields() async -> Bool
    /// Text that came without a key, for the host's focused field.
    func sendText(_ text: String) async -> TextDelivery
    /// Starts or stops host cursor shapes; false when the host does not take them.
    func setCursorShapes(_ enabled: Bool) async -> Bool
    func takeCursorShapes() async -> [HostCursorShape]
    func requestVideoRecovery()
    func setMicrophoneMuted(_ muted: Bool)
    func send(_ event: RemoteInputEvent) -> Bool
    func beginAdaptiveBitrate(ceiling: UInt32, current: UInt32) async -> Bool
    func suggestedBitrate(decodeMillis: Float) async -> UInt32?
    func appliedBitrate(requested: UInt32, applied: UInt32) async
    func healthTick(_ timings: HealthTimings) async -> NetworkMeasures?
    func healthReport(currentKbps: UInt32,runtimeBitrate: Bool,automatic: Bool,busy: Bool) async -> StreamHealthReport?
    func trialBegin(undo: Bool,liveKbps: UInt32) async -> Result<UInt32,TrialRefusal>
    func trialApplied(undo: Bool,previousKbps: UInt32,appliedKbps: UInt32) async
    func trialClear() async
    /// The display's EDR headroom; whether the host took it (unchanged values count).
    func reportDisplay(headroom: Float) async -> DisplayReport
    /// Starts the timing CSV; false when it could not.
    func openTimingCSV(path: String) async -> Bool
    func timingRow(_ shown: PictureShown) async
    /// Sends a clock sync probe; the offset, round trip and the offset's clock now, once known.
    func clockSync() async -> (offsetMicros: Int64,roundTripMicros: Int64,clockNowMicros: UInt64)?
    /// One frame about to be shown, for phase lock; the lead when a report went to the host.
    func phaseSample(readyMicros: UInt64,nowMicros: UInt64,latchMicros: Int64,periodNanos: Int64) async -> Int32?
    /// The network toward the host changed; nil when no stream is running.
    func networkChanged(metered: Bool) async -> NetworkChange?
    /// Automatic quality: nil when it could not start, false when the host takes no size changes.
    func qualityBegin(_ mode: AutomaticQuality,minShortEdge: UInt32,minFps: UInt32) async -> Bool?
    func qualityTick(decodedWidth: UInt32,decodedHeight: UInt32,suspended: Bool) async -> QualityTick?
    func qualityEnd() async
}

enum DisplayReport: Equatable, Sendable { case sent, unchanged, unsupported, failed }
/// `noField`: the host says no text field has focus, so the text did not go.
enum TextDelivery: Equatable, Sendable { case sent, noField, failed }

/// The app's side of a stream doctor tick: its own recent timings, NaN when unknown.
struct HealthTimings: Sendable {
    var decodeMs=Float.nan,hostP95Ms=Float.nan,displayP95Ms=Float.nan,releasedFps=Float.nan,shownFps=Float.nan
    var thermalLevel: UInt32=0
    var intervalMs: UInt32=1000
}

extension StreamSessionService {
    func healthTick(_ timings: HealthTimings) async -> NetworkMeasures? { nil }
    func healthReport(currentKbps: UInt32,runtimeBitrate: Bool,automatic: Bool,busy: Bool) async -> StreamHealthReport? { nil }
    func trialBegin(undo: Bool,liveKbps: UInt32) async -> Result<UInt32,TrialRefusal> { .failure(.unavailable) }
    func trialApplied(undo: Bool,previousKbps: UInt32,appliedKbps: UInt32) async {}
    func trialClear() async {}
    func reportDisplay(headroom: Float) async -> DisplayReport { .unsupported }
    func phaseSample(readyMicros: UInt64,nowMicros: UInt64,latchMicros: Int64,periodNanos: Int64) async -> Int32? { nil }
    func clockSync() async -> (offsetMicros: Int64,roundTripMicros: Int64,clockNowMicros: UInt64)? { nil }
    func openTimingCSV(path: String) async -> Bool { false }
    func timingRow(_ shown: PictureShown) async {}
    func networkChanged(metered: Bool) async -> NetworkChange? { nil }
    func qualityBegin(_ mode: AutomaticQuality,minShortEdge: UInt32,minFps: UInt32) async -> Bool? { false }
    func qualityTick(decodedWidth: UInt32,decodedHeight: UInt32,suspended: Bool) async -> QualityTick? { nil }
    func qualityEnd() async {}
    func reportKeyboardLayout(_ layout: KeyboardLayoutReport) async -> Bool { false }
    func requestTextFields() async -> Bool { false }
    func sendText(_ text: String) async -> TextDelivery { .failed }
    func setCursorShapes(_ enabled: Bool) async -> Bool { false }
    func takeCursorShapes() async -> [HostCursorShape] { [] }
    func liveRates(kbps: UInt32,fpsMilliHz: UInt32) async throws -> LiveRates { throw HostConnectionError("Live rate controls are unavailable.") }
    func clipboardStep(active: Bool,baseline: Bool,text: String?) async throws -> ClipboardSyncResult {
        ClipboardSyncResult(available:false,text:nil)
    }
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
    func healthTick(_ timings: HealthTimings) async -> NetworkMeasures? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? try? engine.healthTick(decodeMs:timings.decodeMs,hostP95Ms:timings.hostP95Ms,
                displayP95Ms:timings.displayP95Ms,releasedFps:timings.releasedFps,shownFps:timings.shownFps,
                thermalLevel:timings.thermalLevel,intervalMs:timings.intervalMs,nowMillis:Self.nowMillis()) : nil)
        } }
    }
    func healthReport(currentKbps: UInt32,runtimeBitrate: Bool,automatic: Bool,busy: Bool) async -> StreamHealthReport? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? try? engine.healthReport(nowMillis:Self.nowMillis(),currentKbps:currentKbps,
                runtimeBitrate:runtimeBitrate,automatic:automatic,busy:busy) : nil)
        } }
    }
    func trialBegin(undo: Bool,liveKbps: UInt32) async -> Result<UInt32,TrialRefusal> {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.trialBegin(undo:undo,liveKbps:liveKbps) : .failure(.unavailable))
        } }
    }
    func trialApplied(undo: Bool,previousKbps: UInt32,appliedKbps: UInt32) async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if acceptingInput { engine.trialApplied(undo:undo,previousKbps:previousKbps,appliedKbps:appliedKbps) }
            continuation.resume()
        } }
    }
    func trialClear() async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if acceptingInput { engine.trialClear() }
            continuation.resume()
        } }
    }
    func liveRates(kbps: UInt32,fpsMilliHz: UInt32) async throws -> LiveRates {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                guard acceptingInput else { throw HostConnectionError("No stream is running.") }
                continuation.resume(returning:try engine.liveRates(kbps:kbps,fpsMilliHz:fpsMilliHz))
            } catch { continuation.resume(throwing:error) }
        } }
    }
    func takeControllerFeedback() async -> [ControllerFeedback] {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.takeControllerFeedback() : [])
        } }
    }
    func reportKeyboardLayout(_ layout: KeyboardLayoutReport) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput && (try? engine.reportKeyboardLayout(layout)) != nil)
        } }
    }
    func requestTextFields() async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput && (try? engine.requestTextFields()) != nil)
        } }
    }
    func sendText(_ text: String) async -> TextDelivery {
        await withCheckedContinuation { continuation in queue.async { [self] in
            guard acceptingInput else { continuation.resume(returning:.failed);return }
            guard engine.textField().takesText else { continuation.resume(returning:.noField);return }
            // Through the input mailbox, so the text stays in order with keys.
            continuation.resume(returning:send(.text(text)) ? .sent : .failed)
        } }
    }
    func setCursorShapes(_ enabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput && (try? engine.cursorShapes(enabled:enabled)) != nil)
        } }
    }
    func takeCursorShapes() async -> [HostCursorShape] {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.takeCursorShapes() : [])
        } }
    }
    func qualityBegin(_ mode: AutomaticQuality,minShortEdge: UInt32,minFps: UInt32) async -> Bool? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            guard acceptingInput else { continuation.resume(returning:nil);return }
            continuation.resume(returning:try? engine.qualityBegin(mode:mode.engineValue,minShortEdge:minShortEdge,minFps:minFps,nowMillis:Self.nowMillis()))
        } }
    }
    func qualityTick(decodedWidth: UInt32,decodedHeight: UInt32,suspended: Bool) async -> QualityTick? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            guard acceptingInput else { continuation.resume(returning:nil);return }
            continuation.resume(returning:try? engine.qualityTick(decodedWidth:decodedWidth,decodedHeight:decodedHeight,suspended:suspended,nowMillis:Self.nowMillis()))
        } }
    }
    func qualityEnd() async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if acceptingInput { engine.qualityEnd() }
            continuation.resume()
        } }
    }
    func networkChanged(metered: Bool) async -> NetworkChange? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? try? engine.networkChanged(metered:metered) : nil)
        } }
    }
    func openTimingCSV(path: String) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:(try? engine.openTimingCSV(path:path)) != nil)
        } }
    }
    func timingRow(_ shown: PictureShown) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in queue.async { [self] in
            defer { continuation.resume() }
            guard acceptingInput else { return }
            // Everything on the engine's clock, which the host offset is measured against.
            let delta=Int64(StreamingEngine.clockNowMicros)-Int64(DispatchTime.now().uptimeNanoseconds/1000)
            func onEngine(_ micros: UInt64) -> UInt64 { micros == 0 ? 0 : UInt64(max(0,Int64(micros)+delta)) }
            let timing=shown.timing
            engine.timingRow(number:timing.number,rtp:timing.rtp,receive:timing.receiveMicros ?? 0,enqueue:timing.enqueueMicros,
                             input:onEngine(timing.submitMicros),output:onEngine(timing.decodedMicros),render:onEngine(shown.renderMicros),
                             hostLatency:timing.hostLatencyTenthMs,drops:shown.drops,due:onEngine(shown.dueMicros),begin:onEngine(shown.beginMicros))
        } }
    }
    func clockSync() async -> (offsetMicros: Int64,roundTripMicros: Int64,clockNowMicros: UInt64)? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.clockSync() : nil)
        } }
    }
    func phaseSample(readyMicros: UInt64,nowMicros: UInt64,latchMicros: Int64,periodNanos: Int64) async -> Int32? {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning:acceptingInput ? engine.phaseSample(readyMicros:readyMicros,nowMicros:nowMicros,latchMicros:latchMicros,periodNanos:periodNanos) : nil)
        } }
    }
    func reportDisplay(headroom: Float) async -> DisplayReport {
        await withCheckedContinuation { continuation in queue.async { [self] in
            guard acceptingInput else { continuation.resume(returning:.failed);return }
            do { continuation.resume(returning:try engine.reportDisplay(headroom:headroom) ? .sent : .unchanged) }
            catch EngineError.unsupportedByHost { continuation.resume(returning:.unsupported) }
            catch { continuation.resume(returning:.failed) }
        } }
    }
    func clipboardStep(active: Bool,baseline: Bool,text: String?) async throws -> ClipboardSyncResult {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                guard acceptingInput else { throw HostConnectionError("No stream is running.") }
                continuation.resume(returning:try engine.clipboardStep(active:active,baseline:baseline,text:text))
            } catch { continuation.resume(throwing:error) }
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
        case let .controllerArrival(slot,mask,capabilities,epoch,kind,buttons):
            try engine.controllerArrival(slot:slot,activeMask:mask,capabilities:capabilities,feedbackEpoch:epoch,kind:kind,buttons:buttons)
        // A host without motion or battery reports refuses them; the stream carries on.
        case let .controllerMotion(slot,kind,x,y,z):
            do { try engine.controllerMotion(slot:slot,kind:kind,x:x,y:y,z:z) } catch EngineError.unsupportedByHost {}
        case let .controllerBattery(slot,battery):
            do { try engine.controllerBattery(slot:slot,battery:battery) } catch EngineError.unsupportedByHost {}
        case let .text(text): try engine.sendText(text)
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
