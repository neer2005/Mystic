import AVFoundation
import CoreMedia
import Foundation
import MysticCore
import MysticKit
import QuartzCore

/// Where decoded pictures are paced and handed to the renderer: one queue that does nothing
/// else, at user-interactive priority. On the main actor a picture waited behind whatever the
/// main thread was doing (SwiftUI, the stream's statistics, a menu); here it waits for nothing.
/// The main actor keeps what belongs to it, the layers' layout and the state the HUD reads, and
/// hears from here only when a picture's size or tags change.
@globalActor
actor PresentationActor {
    static let shared=PresentationActor()
    private static let queue=DispatchSerialQueue(label:"Mystic.Presentation",qos:.userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.queue.asUnownedSerialExecutor() }
}

@PresentationActor
protocol PresentationReceiver: AnyObject, Sendable {
    func enqueue(_ sample: sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult
    func flush()
    func flush(removingDisplayedImage: Bool) async
}

/// The system layer's receiver. Its calls run on the caller's actor, so here they stay off the main one.
@PresentationActor
private final class NativePresentationReceiver: PresentationReceiver {
    /// Made on the main actor and handed over once, then used only here: the compiler cannot see
    /// that through an initializer, so this says it.
    private nonisolated(unsafe) let receiver: AVSampleBufferVideoRenderer.Receiver
    nonisolated init(_ receiver: sending AVSampleBufferVideoRenderer.Receiver) { self.receiver=receiver }
    func enqueue(_ sample: sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult {
        try await receiver.enqueue(CMReadySampleBuffer(unsafeBuffer:sample))
    }
    func flush() { receiver.flush() }
    func flush(removingDisplayedImage: Bool) async { await receiver.flush(removingDisplayedImage:removingDisplayedImage) }
}

/// One picture shown, on the telemetry clock.
public struct PictureShown: Sendable {
    public let timing: VideoFrameTiming
    public let renderMicros: UInt64,drops: UInt64,dueMicros: UInt64,beginMicros: UInt64
}

/// What the presentation queue tells the main actor, in order.
enum PresentationUpdate: Sendable {
    /// A new generation: no picture yet.
    case reset
    case size(CGSize)
    case tags(VideoSourceTags)
}

/// What the app sets on the main actor and the presentation queue calls.
final class PresentationHooks: @unchecked Sendable {
    private let lock=NSLock()
    private var failure: (@Sendable (UInt64,String) -> Void)?
    private var shown: (@Sendable (PictureShown) -> Void)?
    private var change: (@Sendable (PresentationUpdate) -> Void)?
    var decoderFailure: (@Sendable (UInt64,String) -> Void)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure=newValue } }
    }
    var shownReport: (@Sendable (PictureShown) -> Void)? {
        get { lock.withLock { shown } }
        set { lock.withLock { shown=newValue } }
    }
    var update: (@Sendable (PresentationUpdate) -> Void)? {
        get { lock.withLock { change } }
        set { lock.withLock { change=newValue } }
    }
}

/// Attach `layer` to an AppKit view on the main actor. No window or host lifecycle is owned here.
/// The main actor's half of presentation: the layers, their layout and the state the HUD reads.
/// Pictures themselves go through `PresentationLoop`, off the main actor.
@MainActor
public final class DisplayLayerPresenter {
    public let layer: AVSampleBufferDisplayLayer
    /// The layer the owning view shows; `layer`, unless Metal is drawing.
    public var surface: CALayer { metal?.layer ?? layer }
    /// What is drawing the stream, which is the display layer if Metal could not start.
    public var renderer: VideoRendererKind { metal == nil ? .displayLayer : .metal }
    private let metal: MetalPresentationReceiver?
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
        metal?.setDrawableSize(Self.drawableSize(video:videoSize,frame:frame,pixelsPerPoint:pixelsPerPoint))
    }
    /// Metal draws the picture at its own size and Core Animation scales it into the frame: in
    /// full screen the display's scaler does that, with a better filter than the shader's bilinear
    /// one, and resizing the window no longer reallocates the drawables. Before the first frame,
    /// when there is no size yet, the frame's own pixels.
    nonisolated static func drawableSize(video: CGSize,frame: CGRect,pixelsPerPoint: CGFloat) -> CGSize {
        if video.width >= 1,video.height >= 1 { return CGSize(width:video.width.rounded(),height:video.height.rounded()) }
        return CGSize(width:frame.width*pixelsPerPoint,height:frame.height*pixelsPerPoint)
    }
    private let telemetry: VideoTelemetry?
    private let loop: PresentationLoop
    private let pacing: PresentationPacing
    var decoderFailure: (@Sendable (UInt64,String) -> Void)? {
        get { loop.hooks.decoderFailure }
        set { loop.hooks.decoderFailure=newValue }
    }

    public convenience init(telemetry: VideoTelemetry? = nil,mode: FramePacingMode = .lowLatency,vsync: Bool = true,renderer: VideoRendererKind = .displayLayer,
                            onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(telemetry:telemetry,mode:mode,vsync:vsync,renderer:renderer,receiverOverride:nil,onFailure:onFailure)
    }
    init(telemetry: VideoTelemetry?,mode: FramePacingMode,vsync: Bool = true,renderer: VideoRendererKind = .displayLayer,receiverOverride: (any PresentationReceiver)?,
         rendererClock: (@MainActor @Sendable () -> CMTime)? = nil,
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.telemetry=telemetry;pacingMode=mode
        // No check yet that a Mac display refreshes on present, so VRR's modes are not offered.
        let pacing=PresentationPacing.choose(vrr:false,presentAtHostTimes:false,vsync:vsync,framePacing:mode,tearingSupported:false)
        self.pacing=pacing
        let layer=AVSampleBufferDisplayLayer();self.layer=layer
        let synchronizer=AVSampleBufferRenderSynchronizer()
        let native=synchronizer.sampleBufferReceiver(adding:layer.sampleBufferRenderer)
        // Metal's timeline: the synchronizer's clock needs samples it will never get on this path.
        let timeline=MetalTimeline()
        let metal=renderer == .metal && receiverOverride == nil
            ? try? MetalPresentationReceiver(clock:{ timeline.now() },waitsForRefresh:pacing == .vsync) : nil
        self.metal=metal
        let receiver: any PresentationReceiver
        if let receiverOverride { receiver=receiverOverride }
        else if let metal { receiver=metal }
        else { receiver=NativePresentationReceiver(native) }
        synchronizer.delaysRateChangeUntilHasSufficientMediaData=false
        // `videoRect` already holds the shape; the layer exactly covers it.
        layer.videoGravity = .resize
        layer.preferredDynamicRange = .standard
        layer.toneMapMode = .automatic
        loop=PresentationLoop(telemetry:telemetry,synchronizer:synchronizer,receiver:receiver,metal:metal,metalClock:timeline,
                              rendererClock:rendererClock,pacing:pacing,pacingMode:mode,onFailure:onFailure)
        // Through the main queue, so changes arrive in the order the pictures were presented.
        loop.hooks.update={ [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(update) } }
        }
    }
    private func apply(_ update: PresentationUpdate) {
        switch update {
        case .reset: videoSize = .zero;videoOutput.reset();configureDynamicRange()
        case .size(let size): videoSize=size
        case .tags(let tags): videoOutput.update(tags);configureDynamicRange()
        }
    }

    /// Told after every display update, so the stream can report the screen to the host.
    public var displayChanged: (() -> Void)?
    /// Called by the owning view when its actual destination or screen headroom changes.
    public func updateDisplay(name: String?,currentHeadroom: Double?,potentialHeadroom: Double?) {
        videoOutput.updateDisplay(name:name,currentHeadroom:currentHeadroom,potentialHeadroom:potentialHeadroom)
        metal?.setHeadroom(videoOutput.currentHeadroom ?? 1)
        configureDynamicRange()
        displayChanged?()
    }
    /// The screen's current EDR headroom alone, which moves with its brightness and with whether
    /// HDR is on screen, and which the Metal renderer tone maps PQ to. Not a display change: the
    /// host isn't told.
    public func updateHeadroom(_ current: Double?) {
        videoOutput.updateCurrentHeadroom(current)
        metal?.setHeadroom(videoOutput.currentHeadroom ?? 1)
    }
    private func configureDynamicRange() {
        // Preserve the tagged YCbCr surface. Core Animation owns the sole output tone map.
        let range: CALayer.DynamicRange = videoOutput.requestsEDR ? .high : .standard
        if layer.preferredDynamicRange != range { layer.preferredDynamicRange = range }
    }

    /// At most one pending drain, one image in flight, and one waiting image. Called by the
    /// decoder on its own threads.
    nonisolated func offer(_ frame: DecodedVideoFrame) { loop.offer(frame) }
    nonisolated func reset(generation: UInt64) { loop.reset(generation:generation) }
    /// For phase lock: each frame with V-Sync on, as (ready, now, last latch, period) in microseconds
    /// and nanoseconds of the host clock. Only Metal reports when its frames are shown.
    public func reportPhase(_ report: @escaping @Sendable (UInt64,UInt64,Int64,Int64) -> Void) {
        if pacing == .vsync { metal?.setPhaseReport(report) }
    }
    /// For the timing CSV: each picture as it is shown, or on System as it is handed over. Called
    /// on the presentation queue.
    public var shownReport: (@Sendable (PictureShown) -> Void)? {
        get { loop.hooks.shownReport }
        set { loop.hooks.shownReport=newValue }
    }
    /// For the input latency test: on System a frame counts as shown when it is handed over.
    public nonisolated var latencyProbe: LatencyProbe { loop.latencyProbe }
    public var reportsShownFrames: Bool { metal != nil }
    /// Clock sync: `offset` from the host's clock to the engine's, whose time is now `engineNow`.
    public func setClockOffset(_ offset: Int64,engineNow: UInt64) { metal?.setClockOffset(offset,engineNow:engineNow) }
    /// The screen's refresh rate, which phase lock reports to the host.
    public func setRefresh(hertz: Double) { metal?.setRefresh(hertz:hertz) }
    /// Renderer-reported drops are separate from Mystic's queue/policy drops; no scanout claim.
    public func refreshRendererMetrics() async {
        guard let generation=await loop.shownGeneration() else { return }
        if let metal {
            let causes=metal.dropCauses
            telemetry?.rendererMetrics(generation:generation,dropped:causes.total,corrupted:nil,causes:causes)
            telemetry?.presentationShown(generation:generation,cadence:metal.cadence)
            return
        }
        let metrics: AVVideoPerformanceMetrics?=await withCheckedContinuation { continuation in
            layer.sampleBufferRenderer.loadVideoPerformanceMetrics { continuation.resume(returning:$0) }
        }
        guard await loop.shownGeneration() == generation else { return }
        telemetry?.rendererMetrics(generation:generation,
            dropped:metrics.flatMap { $0.numberOfDroppedFrames >= 0 ? UInt64($0.numberOfDroppedFrames) : nil },
            corrupted:metrics.flatMap { $0.numberOfCorruptedFrames >= 0 ? UInt64($0.numberOfCorruptedFrames) : nil })
    }
}

/// Nightjar's stream loop: decoded pictures go to the pacer, and the due one to the screen.
@PresentationActor
final class PresentationLoop {
    nonisolated let hooks=PresentationHooks()
    nonisolated let latencyProbe=LatencyProbe()
    private nonisolated let mailbox: PresentationMailbox
    private let telemetry: VideoTelemetry?
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let receiver: any PresentationReceiver
    private let metal: MetalPresentationReceiver?
    private let metalClock: MetalTimeline
    /// A test's clock, which lives on the main actor.
    private let rendererClock: (@MainActor @Sendable () -> CMTime)?
    private let pacing: PresentationPacing
    private let pacingMode: FramePacingMode
    private let onFailure: @Sendable (String) -> Void
    private var pacer: PresentationPacer<DecodedVideoFrame>
    private var displayedGeneration: UInt64?
    private var anchored=false
    private var waitTask: Task<Void,any Error>?
    private var presenterDrops: UInt64=0
    /// What the main actor was last told, so it is told only of a change.
    private var shownSize: CGSize?
    private var shownTags: VideoSourceTags?

    nonisolated init(telemetry: VideoTelemetry?,synchronizer: AVSampleBufferRenderSynchronizer,receiver: any PresentationReceiver,
                     metal: MetalPresentationReceiver?,metalClock: MetalTimeline,rendererClock: (@MainActor @Sendable () -> CMTime)?,
                     pacing: PresentationPacing,pacingMode: FramePacingMode,onFailure: @escaping @Sendable (String) -> Void) {
        self.telemetry=telemetry;self.synchronizer=synchronizer;self.receiver=receiver;self.metal=metal;self.metalClock=metalClock
        self.rendererClock=rendererClock;self.pacing=pacing;self.pacingMode=pacingMode;self.onFailure=onFailure
        pacer=PresentationPacer(mode:pacing,framePacing:pacingMode)
        mailbox=PresentationMailbox(telemetry:telemetry,capacity:pacing.mailboxLimit)
    }

    nonisolated func offer(_ frame: DecodedVideoFrame) { if mailbox.offer(frame) { scheduleDrain() } }
    nonisolated func reset(generation: UInt64) {
        let schedule=mailbox.reset(generation:generation)
        if mailbox.reserveWake() { Task { @PresentationActor in self.wake() } }
        if schedule { scheduleDrain() }
    }
    private nonisolated func scheduleDrain() { Task { @PresentationActor in await self.drain() } }
    /// A reset ends a wait or a suspended enqueue for the generation it replaced.
    private func wake() {
        let latest=mailbox.finishWake()
        guard mailbox.isCurrent(latest),displayedGeneration != latest else { return }
        waitTask?.cancel()
        receiver.flush()
    }
    /// The generation on screen, while it is still the stream's.
    func shownGeneration() -> UInt64? {
        guard let generation=displayedGeneration,mailbox.isCurrent(generation) else { return nil }
        return generation
    }
    private func tell(_ update: PresentationUpdate) { hooks.update?(update) }
    private func drain() async {
        defer { if mailbox.finish() { scheduleDrain() } }
        do {
            while true {
                let work=mailbox.take()
                guard mailbox.isCurrent(work.generation) else { return }
                if displayedGeneration != work.generation {
                    await receiver.flush(removingDisplayedImage:true)
                    guard mailbox.isCurrent(work.generation) else { return }
                    if displayedGeneration != nil { telemetry?.presentationResynchronize(generation:work.generation) }
                    displayedGeneration=work.generation;pacer=PresentationPacer(mode:pacing,framePacing:pacingMode);anchored=false
                    shownSize=nil;shownTags=nil;tell(.reset)
                    synchronizer.setRate(0,time:.zero);metalClock.restart()
                }
                if let frame=work.frame {
                    if let host=Self.micros(frame.presentationTime) {
                        let now=VideoTelemetry.nowMicros()
                        let ready=frame.timing.map { min($0.decodedMicros,now) } ?? now
                        pacer.set(frameRate:frame.frameRate)
                        pacer.accept(frame,readyMicros:Int64(ready),hostMicros:host)
                    } else {
                        telemetry?.presentationDrop(generation:frame.generation,reason:.invalidTimestamp)
                    }
                    continue
                }
                let now=Int64(VideoTelemetry.nowMicros())
                let (due,dropped)=pacer.takeDue(now:now)
                presenterDrops &+= UInt64(dropped)
                if dropped > 0 { telemetry?.presentationDrop(generation:work.generation,reason:.superseded,count:UInt64(dropped)) }
                if let due {
                    try await present(due)
                    continue
                }
                guard let next=pacer.nextDueMicros else { return }
                let wait=Task { try await Task.sleep(for:.microseconds(max(0,next-now))) }
                waitTask=wait
                defer { waitTask=nil }
                // A reset cancels the wait; it is not a failure.
                guard (try? await wait.value) != nil else { return }
            }
        } catch {
            receiver.flush()
            let generation=mailbox.currentGeneration
            telemetry?.presentationDrop(generation:generation,reason:.enqueueFailure)
            hooks.decoderFailure?(generation,String(describing:error));onFailure(String(describing:error))
        }
    }
    private func present(_ due: PresentationPacer<DecodedVideoFrame>.Pending) async throws {
        let frame=due.picture
        if !anchored { synchronizer.setRate(1,time:.zero);metalClock.restart();anchored=true }
        let clock: CMTime
        if let rendererClock { clock=await rendererClock() }
        else { clock=metal == nil ? synchronizer.currentTime() : metalClock.now() }
        guard let rendererNow=Self.micros(clock) else {
            throw VideoDecoderError.invalidSample("invalid renderer clock")
        }
        let sample=try frame.sampleBuffer(presentationTime:CMTime(value:rendererNow,timescale:1_000_000))
        if let description=CMSampleBufferGetFormatDescription(sample) {
            let size=CMVideoFormatDescriptionGetPresentationDimensions(description,usePixelAspectRatio:true,useCleanAperture:true)
            if size != shownSize { shownSize=size;tell(.size(size)) }
        }
        guard mailbox.isCurrent(frame.generation) else { return }
        let tags=VideoSourceTags(image:frame.pixelBuffer)
        if tags != shownTags { shownTags=tags;tell(.tags(tags)) }
        let enqueueStarted=VideoTelemetry.nowMicros()
        metal?.nextFrameAge=Double(max(0,Int64(enqueueStarted)-due.readyMicros))/1_000_000
        metal?.nextFrameTiming=frame.timing
        let report=hooks.shownReport,drops=presenterDrops,dueMicros=UInt64(max(0,due.presentMicros))
        let probe=latencyProbe.armed ? latencyProbe : nil
        if let timing=frame.timing,report != nil || probe != nil {
            metal?.nextFrameShown={ seconds in
                let render=VideoTelemetry.nowMicros()-UInt64(max(0,(CACurrentMediaTime()-seconds)*1_000_000))
                report?(PictureShown(timing:timing,renderMicros:render,drops:drops,dueMicros:dueMicros,beginMicros:enqueueStarted))
                probe?.frameRendered(timing,renderMicros:render)
            }
        } else { metal?.nextFrameShown=nil }
        let result=try await receiver.enqueue(sample)
        guard mailbox.isCurrent(frame.generation) else { return }
        try checkEnqueue(result)
        if case .cancelledDueToFlush = result { return }
        if metal == nil,let timing=frame.timing {
            report?(PictureShown(timing:timing,renderMicros:VideoTelemetry.nowMicros(),drops:presenterDrops,dueMicros:UInt64(max(0,due.presentMicros)),beginMicros:enqueueStarted))
            probe?.frameRendered(timing,renderMicros:VideoTelemetry.nowMicros())
        }
        if due.late { telemetry?.presentationLate(generation:frame.generation) }
        if let hold=pacer.lastHoldMicros { telemetry?.presentationHold(generation:frame.generation,micros:hold) }
        if let timing=frame.timing {
            telemetry?.enqueue(generation:frame.generation,timing:timing,startMicros:enqueueStarted,endMicros:VideoTelemetry.nowMicros())
        }
    }
    private static func micros(_ time: CMTime) -> Int64? {
        guard time.isNumeric else { return nil }
        let scaled=CMTimeConvertScale(time,timescale:1_000_000,method:.default)
        return scaled.isNumeric && scaled.value >= 0 ? scaled.value : nil
    }
}

private extension LatencyProbe {
    /// Frames' receive times are on the engine's clock and the presenter's on the system's.
    func frameRendered(_ timing: VideoFrameTiming,renderMicros: UInt64) {
        guard let receive=timing.receiveMicros else { return }
        let delta=Int64(StreamingEngine.clockNowMicros)-Int64(VideoTelemetry.nowMicros())
        frameRendered(receive:Int64(receive),render:Int64(renderMicros)+delta)
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
    var currentGeneration: UInt64 { lock.lock();defer { lock.unlock() };return generation }
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
