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
    /// The layer the owning view shows; `layer`, unless Metal is drawing.
    public var surface: CALayer { metal?.layer ?? layer }
    /// What is drawing the stream, which is the display layer if Metal could not start.
    public var renderer: VideoRendererKind { metal == nil ? .displayLayer : .metal }
    private let metal: MetalPresentationReceiver?
    /// Metal's timeline: the synchronizer's clock needs samples it will never get on this path.
    private let metalClock=MetalTimeline()
    public let pacingMode: FramePacingMode
    public let videoOutput = VideoOutputState()
    public private(set) var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { applyLayout() } } }
    /// Where the picture sits in the owning view, which may overhang it; empty before a frame.
    public var videoRect: CGRect { sizing.rect(video:videoSize,in:container,pixelsPerPoint:pixelsPerPoint,alignTop:alignTop) }
    private var container: CGRect = .zero
    private var pixelsPerPoint: CGFloat=1
    private var sizing: VideoSizing = .fit
    private var alignTop=false
    /// The owning view's bounds and screen scale.
    public func layout(in bounds: CGRect,pixelsPerPoint: CGFloat) {
        container=bounds;self.pixelsPerPoint=pixelsPerPoint;applyLayout()
    }
    public func setSizing(_ sizing: VideoSizing,alignTop: Bool) {
        self.sizing=sizing;self.alignTop=alignTop;applyLayout()
    }
    private func applyLayout() {
        let rect=videoRect
        CATransaction.begin();CATransaction.setDisableActions(true)
        let frame=rect.isEmpty ? container : rect
        surface.frame=frame
        CATransaction.commit()
        metal?.setDrawableSize(CGSize(width:frame.width*pixelsPerPoint,height:frame.height*pixelsPerPoint))
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

    public convenience init(telemetry: VideoTelemetry? = nil,mode: FramePacingMode = .lowLatency,renderer: VideoRendererKind = .displayLayer,
                            onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(telemetry:telemetry,mode:mode,renderer:renderer,receiverOverride:nil,onFailure:onFailure)
    }
    init(telemetry: VideoTelemetry?,mode: FramePacingMode,renderer: VideoRendererKind = .displayLayer,receiverOverride: (any PresentationReceiver)?,
         rendererClock: (@MainActor () -> CMTime)? = nil,
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.telemetry=telemetry;self.onFailure=onFailure;pacingMode=mode;pacer=FramePacer(mode:mode);self.rendererClock=rendererClock
        mailbox=PresentationMailbox(telemetry:telemetry,capacity:mode.retainedFrames)
        let layer=AVSampleBufferDisplayLayer();self.layer=layer
        let native=synchronizer.sampleBufferReceiver(adding:layer.sampleBufferRenderer)
        let timeline=metalClock
        let metal=renderer == .metal && receiverOverride == nil
            ? try? MetalPresentationReceiver(clock:{ timeline.now() },capacity:mode.retainedFrames) : nil
        self.metal=metal
        receiver=receiverOverride ?? metal ?? NativePresentationReceiver(native)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData=false
        // `videoRect` already holds the shape; the layer exactly covers it.
        layer.videoGravity = .resize
        layer.preferredDynamicRange = .standard
        layer.toneMapMode = .automatic
    }

    /// Told after every display update, so the stream can report the screen to the host.
    public var displayChanged: (() -> Void)?
    /// Called by the owning view when its actual destination or screen headroom changes.
    public func updateDisplay(name: String?,currentHeadroom: Double?,potentialHeadroom: Double?) {
        videoOutput.updateDisplay(name:name,currentHeadroom:currentHeadroom,potentialHeadroom:potentialHeadroom)
        configureDynamicRange()
        displayChanged?()
    }
    private func configureDynamicRange() {
        // Preserve the tagged YCbCr surface. Core Animation owns the sole output tone map.
        let range: CALayer.DynamicRange = videoOutput.requestsEDR ? .high : .standard
        if layer.preferredDynamicRange != range { layer.preferredDynamicRange = range }
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
            videoOutput.reset();configureDynamicRange()
            synchronizer.setRate(0,time:.zero);metalClock.restart()
        }
        guard let frame=work.frame else { return }
        do {
            guard let sourcePTS=Self.micros(frame.presentationTime) else {
                telemetry?.presentationDrop(generation:frame.generation,reason:.invalidTimestamp);return
            }
            if !anchored { synchronizer.setRate(1,time:.zero);metalClock.restart();anchored=true }
            while mailbox.isCurrent(frame.generation) {
                let now=VideoTelemetry.nowMicros()
                let age=frame.timing.flatMap { now >= $0.decodedMicros ? now-$0.decodedMicros : nil }
                if mailbox.hasNewerFrame(than:frame),pacer.isSuperseded(ageMicros:age,frameRate:frame.frameRate) {
                    telemetry?.presentationDrop(generation:frame.generation,reason:.superseded);return
                }
                guard let rendererNow=Self.micros(rendererClock?() ?? (metal == nil ? synchronizer.currentTime() : metalClock.now())) else {
                    throw VideoDecoderError.invalidSample("invalid renderer clock")
                }
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
                    videoOutput.update(image:frame.pixelBuffer);configureDynamicRange()
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
        if let metal {
            telemetry?.rendererMetrics(generation:generation,dropped:metal.droppedFrames,corrupted:nil)
            return
        }
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

/// Up to `capacity` pending images plus one suspended enqueue. Counters share the mailbox lock's ordering.
final class PresentationMailbox: @unchecked Sendable {
    private let lock=NSLock()
    private let telemetry: VideoTelemetry?
    private var generation: UInt64=0
    private let capacity: Int
    private var frames: [DecodedVideoFrame]=[]
    private var inFlightGeneration: UInt64?
    private var scheduled=false,dirty=false,wakeScheduled=false
    init(telemetry: VideoTelemetry? = nil,capacity: Int = 1) { self.telemetry=telemetry;self.capacity=max(1,capacity) }
    private func reportQueue() {
        telemetry?.presentationQueue(generation:generation,depth:frames.count + (inFlightGeneration == generation ? 1 : 0))
    }
    func reserveWake() -> Bool {
        lock.lock();defer { lock.unlock() };guard !wakeScheduled else { return false };wakeScheduled=true;return true
    }
    func finishWake() -> UInt64 { lock.lock();defer { lock.unlock() };wakeScheduled=false;return generation }
    func reset(generation: UInt64) -> Bool {
        lock.lock();defer { lock.unlock() };guard generation >= self.generation else { return false }
        let discarded=UInt64(frames.count + (inFlightGeneration == self.generation ? 1 : 0))
        self.generation=generation;frames=[];inFlightGeneration=nil;dirty=true
        if discarded > 0 { telemetry?.presentationDrop(generation:generation,reason:.reset,count:discarded) }
        reportQueue()
        if scheduled { return false };scheduled=true;return true
    }
    func offer(_ image: DecodedVideoFrame) -> Bool {
        lock.lock();defer { lock.unlock() };guard image.generation == generation else { return false }
        guard image.presentationTime.isNumeric else {
            telemetry?.presentationDrop(generation:generation,reason:.invalidTimestamp);return false
        }
        if let last=frames.last,CMTimeCompare(image.presentationTime,last.presentationTime) <= 0 {
            telemetry?.presentationDrop(generation:generation,reason:.outOfOrder);return false
        }
        if frames.count >= capacity {
            frames.removeFirst();telemetry?.presentationDrop(generation:generation,reason:.superseded)
        }
        frames.append(image);dirty=true;reportQueue()
        if scheduled { return false };scheduled=true;return true
    }
    func take() -> (generation: UInt64,frame: DecodedVideoFrame?) {
        lock.lock();defer { lock.unlock() };dirty=false
        let frame=frames.isEmpty ? nil : frames.removeFirst()
        if frame != nil { inFlightGeneration=generation };reportQueue();return (generation,frame)
    }
    func finish() -> Bool {
        lock.lock();defer { lock.unlock() };inFlightGeneration=nil;reportQueue()
        if dirty || !frames.isEmpty { return true };scheduled=false;return false
    }
    func hasNewerFrame(than current: DecodedVideoFrame) -> Bool {
        lock.lock();defer { lock.unlock() }
        guard let frame=frames.first,frame.generation == current.generation else { return false }
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
