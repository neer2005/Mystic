import AVFoundation
import CoreMedia
import Foundation
import MysticCore

@MainActor
protocol PresentationReceiver: AnyObject {
    func enqueue(_ sample: sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult
    func flush()
    func flush(removingDisplayedImage: Bool) async
}

@MainActor
private final class NativePresentationReceiver: PresentationReceiver {
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    init(_ receiver: AVSampleBufferVideoRenderer.Receiver) { self.receiver=receiver }
    func enqueue(_ sample: sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult {
        try await receiver.enqueue(CMReadySampleBuffer(unsafeBuffer:sample))
    }
    func flush() { receiver.flush() }
    func flush(removingDisplayedImage: Bool) async { await receiver.flush(removingDisplayedImage:removingDisplayedImage) }
}

/// Attach `layer` to an AppKit view on the main actor. No window or host lifecycle is owned here.
@MainActor
public final class DisplayLayerPresenter {
    public let layer: AVSampleBufferDisplayLayer
    public let pacingMode: FramePacingMode
    public private(set) var videoSize: CGSize = .zero
    public var videoRect: CGRect {
        guard videoSize.width > 0,videoSize.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio:videoSize,insideRect:layer.bounds)
    }
    private let telemetry: VideoTelemetry?
    private let synchronizer=AVSampleBufferRenderSynchronizer()
    private let receiver: any PresentationReceiver
    private let rendererClock: (@MainActor () -> CMTime)?
    private nonisolated let mailbox: PresentationMailbox
    private var displayedGeneration: UInt64?
    private var pacer: FramePacer
    private var anchored=false
    private var waitTask: Task<Void,any Error>?
    var isWaitingForPresentation: Bool { waitTask != nil }
    private let onFailure: @Sendable (String) -> Void
    var decoderFailure: (@Sendable (UInt64,String) -> Void)?

    public convenience init(telemetry: VideoTelemetry? = nil,mode: FramePacingMode = .lowLatency,
                            onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(telemetry:telemetry,mode:mode,receiverOverride:nil,onFailure:onFailure)
    }
    init(telemetry: VideoTelemetry?,mode: FramePacingMode,receiverOverride: (any PresentationReceiver)?,
         rendererClock: (@MainActor () -> CMTime)? = nil,
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.telemetry=telemetry;self.onFailure=onFailure;pacingMode=mode;pacer=FramePacer(mode:mode);self.rendererClock=rendererClock
        mailbox=PresentationMailbox(telemetry:telemetry)
        let layer=AVSampleBufferDisplayLayer();self.layer=layer
        let native=synchronizer.sampleBufferReceiver(adding:layer.sampleBufferRenderer)
        receiver=receiverOverride ?? NativePresentationReceiver(native)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData=false
        layer.videoGravity = .resizeAspect
    }

    /// At most one pending actor task, one image in flight, and one waiting image.
    nonisolated func offer(_ frame: DecodedVideoFrame) { if mailbox.offer(frame) { scheduleDrain() } }
    nonisolated func reset(generation: UInt64) {
        let schedule=mailbox.reset(generation:generation)
        if mailbox.reserveWake() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let latest=self.mailbox.finishWake()
                guard self.mailbox.isCurrent(latest),self.displayedGeneration != latest else { return }
                self.waitTask?.cancel()
                self.receiver.flush()
            }
        }
        if schedule { scheduleDrain() }
    }
    private nonisolated func scheduleDrain() { Task { @MainActor [weak self] in await self?.drain() } }
    private func drain() async {
        let work=mailbox.take()
        defer { if mailbox.finish() { scheduleDrain() } }
        guard mailbox.isCurrent(work.generation) else { return }
        if displayedGeneration != work.generation {
            await receiver.flush(removingDisplayedImage:true)
            guard mailbox.isCurrent(work.generation) else { return }
            if pacer.hasAcceptedFrame { telemetry?.presentationResynchronize(generation:work.generation) }
            displayedGeneration=work.generation;pacer.reset();anchored=false;videoSize = .zero
            synchronizer.setRate(0,time:.zero)
        }
        guard let frame=work.frame else { return }
        do {
            guard let sourcePTS=Self.micros(frame.presentationTime) else {
                telemetry?.presentationDrop(generation:frame.generation,reason:.invalidTimestamp);return
            }
            if !anchored { synchronizer.setRate(1,time:.zero);anchored=true }
            while mailbox.isCurrent(frame.generation) {
                if mailbox.hasNewerFrame(than:frame) {
                    telemetry?.presentationDrop(generation:frame.generation,reason:.superseded);return
                }
                guard let rendererNow=Self.micros(rendererClock?() ?? synchronizer.currentTime()) else {
                    throw VideoDecoderError.invalidSample("invalid renderer clock")
                }
                let now=VideoTelemetry.nowMicros()
                let age=frame.timing.flatMap { now >= $0.decodedMicros ? now-$0.decodedMicros : nil }
                switch pacer.plan(sourcePTS:sourcePTS,rendererNow:rendererNow,ageMicros:age,frameRate:frame.frameRate).action {
                case .drop(let reason): telemetry?.presentationDrop(generation:frame.generation,reason:reason);return
                case .recoverTimestamp:
                    telemetry?.presentationDrop(generation:frame.generation,reason:.invalidTimestamp)
                    receiver.flush()
                    let reason="Presentation timestamp discontinuity; resetting video timeline"
                    decoderFailure?(frame.generation,reason);onFailure(reason);return
                case .wait(let delay):
                    let wait=Task { try await Task.sleep(for:.microseconds(delay)) }
                    waitTask=wait
                    do { try await wait.value;waitTask=nil }
                    catch { waitTask=nil;throw error }
                    // Recheck generation, freshness, source ordering and the newest image after waiting.
                    continue
                case let .enqueue(time,late,resynchronize):
                    if resynchronize {
                        await receiver.flush(removingDisplayedImage:false)
                        guard mailbox.isCurrent(frame.generation) else { return }
                        telemetry?.presentationResynchronize(generation:frame.generation)
                    }
                    let sample=try frame.sampleBuffer(presentationTime:CMTime(value:time,timescale:1_000_000))
                    if let description=CMSampleBufferGetFormatDescription(sample) {
                        videoSize=CMVideoFormatDescriptionGetPresentationDimensions(description,usePixelAspectRatio:true,useCleanAperture:true)
                    }
                    guard mailbox.isCurrent(frame.generation) else { return }
                    let enqueueStarted=VideoTelemetry.nowMicros()
                    let result=try await receiver.enqueue(sample)
                    guard mailbox.isCurrent(frame.generation) else { return }
                    try checkEnqueue(result)
                    if case .cancelledDueToFlush = result { return }
                    if late { telemetry?.presentationLate(generation:frame.generation) }
                    if let timing=frame.timing {
                        telemetry?.enqueue(generation:frame.generation,timing:timing,startMicros:enqueueStarted,endMicros:VideoTelemetry.nowMicros())
                    }
                    pacer.accepted(sourcePTS:sourcePTS,rendererNow:rendererNow)
                    return
                }
            }
        } catch {
            receiver.flush()
            guard mailbox.isCurrent(work.generation) else { return }
            telemetry?.presentationDrop(generation:work.generation,reason:.enqueueFailure)
            decoderFailure?(work.generation,String(describing:error));onFailure(String(describing:error))
        }
    }
    /// Renderer-reported drops are separate from Mystic's queue/policy drops; no scanout claim.
    public func refreshRendererMetrics() async {
        guard let generation=displayedGeneration,mailbox.isCurrent(generation) else { return }
        let metrics: AVVideoPerformanceMetrics?=await withCheckedContinuation { continuation in
            layer.sampleBufferRenderer.loadVideoPerformanceMetrics { continuation.resume(returning:$0) }
        }
        guard mailbox.isCurrent(generation),displayedGeneration == generation else { return }
        telemetry?.rendererMetrics(generation:generation,
            dropped:metrics.flatMap { $0.numberOfDroppedFrames >= 0 ? UInt64($0.numberOfDroppedFrames) : nil },
            corrupted:metrics.flatMap { $0.numberOfCorruptedFrames >= 0 ? UInt64($0.numberOfCorruptedFrames) : nil })
    }
    private static func micros(_ time: CMTime) -> Int64? {
        guard time.isNumeric else { return nil }
        let scaled=CMTimeConvertScale(time,timescale:1_000_000,method:.default)
        return scaled.isNumeric && scaled.value >= 0 ? scaled.value : nil
    }
}

/// One pending image plus one suspended enqueue. Counters share the mailbox lock's ordering.
final class PresentationMailbox: @unchecked Sendable {
    private let lock=NSLock()
    private let telemetry: VideoTelemetry?
    private var generation: UInt64=0
    private var frame: DecodedVideoFrame?
    private var inFlightGeneration: UInt64?
    private var scheduled=false,dirty=false,wakeScheduled=false
    init(telemetry: VideoTelemetry? = nil) { self.telemetry=telemetry }
    private func reportQueue() {
        telemetry?.presentationQueue(generation:generation,depth:(frame == nil ? 0 : 1) + (inFlightGeneration == generation ? 1 : 0))
    }
    func reserveWake() -> Bool {
        lock.lock();defer { lock.unlock() };guard !wakeScheduled else { return false };wakeScheduled=true;return true
    }
    func finishWake() -> UInt64 { lock.lock();defer { lock.unlock() };wakeScheduled=false;return generation }
    func reset(generation: UInt64) -> Bool {
        lock.lock();defer { lock.unlock() };guard generation >= self.generation else { return false }
        let discarded=UInt64((frame == nil ? 0 : 1) + (inFlightGeneration == self.generation ? 1 : 0))
        self.generation=generation;frame=nil;inFlightGeneration=nil;dirty=true
        if discarded > 0 { telemetry?.presentationDrop(generation:generation,reason:.reset,count:discarded) }
        reportQueue()
        if scheduled { return false };scheduled=true;return true
    }
    func offer(_ image: DecodedVideoFrame) -> Bool {
        lock.lock();defer { lock.unlock() };guard image.generation == generation else { return false }
        guard image.presentationTime.isNumeric else {
            telemetry?.presentationDrop(generation:generation,reason:.invalidTimestamp);return false
        }
        if let frame,CMTimeCompare(image.presentationTime,frame.presentationTime) <= 0 {
            telemetry?.presentationDrop(generation:generation,reason:.outOfOrder);return false
        }
        if frame != nil { telemetry?.presentationDrop(generation:generation,reason:.superseded) }
        frame=image;dirty=true;reportQueue()
        if scheduled { return false };scheduled=true;return true
    }
    func take() -> (generation: UInt64,frame: DecodedVideoFrame?) {
        lock.lock();defer { lock.unlock() };dirty=false
        let result=(generation,frame);if frame != nil { inFlightGeneration=generation };frame=nil;reportQueue();return result
    }
    func finish() -> Bool {
        lock.lock();defer { lock.unlock() };inFlightGeneration=nil;reportQueue()
        if dirty { return true };scheduled=false;return false
    }
    func hasNewerFrame(than current: DecodedVideoFrame) -> Bool {
        lock.lock();defer { lock.unlock() }
        guard let frame,frame.generation == current.generation else { return false }
        return CMTimeCompare(frame.presentationTime,current.presentationTime) > 0
    }
    func isCurrent(_ value: UInt64) -> Bool { lock.lock();defer { lock.unlock() };return value == generation }
}

func checkEnqueue(_ result: AVSampleBufferVideoRenderer.Receiver.EnqueueResult) throws {
    switch result {
    case .enqueued,.cancelledDueToFlush: return
    case .enqueuedWithDecodeFailures(let errors): throw VideoDecoderError.unsupported("display conversion failed: \(errors)")
    case .cancelledDueToFlushRequiredToResume(let error),.cancelledDueToError(let error): throw error
    @unknown default: throw VideoDecoderError.unsupported("unknown display enqueue result")
    }
}
