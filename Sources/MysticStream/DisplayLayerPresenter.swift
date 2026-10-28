import AVFoundation
import CoreMedia
import Foundation

/// Attach `layer` to an AppKit view on the main actor. No window or host lifecycle is owned here.
@MainActor
public final class DisplayLayerPresenter {
    public let layer: AVSampleBufferDisplayLayer
    public private(set) var videoSize: CGSize = .zero
    /// The aspect-fit image rectangle, including clean aperture and pixel aspect ratio.
    public var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: videoSize, insideRect: layer.bounds)
    }
    private let telemetry: VideoTelemetry?
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private nonisolated let mailbox = PresentationMailbox()
    private var displayedGeneration: UInt64?
    private var lastPTS: CMTime?
    private var anchored = false
    private let onFailure: @Sendable (String) -> Void
    var decoderFailure: (@Sendable (UInt64, String) -> Void)?

    public init(telemetry: VideoTelemetry? = nil, onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.telemetry = telemetry
        self.onFailure = onFailure
        let layer = AVSampleBufferDisplayLayer()
        self.layer = layer
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        layer.videoGravity = .resizeAspect
    }

    /// Thread safe, with at most one pending main-actor task and one pending image.
    nonisolated func offer(_ frame: DecodedVideoFrame) {
        if mailbox.offer(frame) { scheduleDrain() }
    }
    nonisolated func reset(generation: UInt64) {
        let schedule = mailbox.reset(generation: generation)
        // Cancel a suspended enqueue so stop never waits for presentation backpressure.
        if mailbox.reserveWake() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let latest = self.mailbox.finishWake()
                guard self.mailbox.isCurrent(latest), self.displayedGeneration != latest else { return }
                self.receiver.flush()
            }
        }
        if schedule { scheduleDrain() }
    }
    private nonisolated func scheduleDrain() {
        Task { @MainActor [weak self] in await self?.drain() }
    }
    private func drain() async {
        let work = mailbox.take()
        defer { if mailbox.finish() { scheduleDrain() } }
        guard mailbox.isCurrent(work.generation) else { return }
        if displayedGeneration != work.generation {
            await receiver.flush(removingDisplayedImage: true)
            guard mailbox.isCurrent(work.generation) else { return }
            displayedGeneration = work.generation
            lastPTS = nil; anchored = false; videoSize = .zero
            synchronizer.setRate(0, time: .zero)
        }
        guard let frame = work.frame else { return }
        do {
            if let lastPTS, CMTimeCompare(frame.presentationTime, lastPTS) <= 0 { return }
            if !anchored {
                synchronizer.setRate(1, time: frame.presentationTime)
                anchored = true
            }
            // Bound future scheduling too; corrupt timestamps cannot fill the renderer queue.
            let delta = CMTimeGetSeconds(CMTimeSubtract(frame.presentationTime, synchronizer.currentTime()))
            guard delta >= -0.1, delta <= 0.1 else { return }
            let sample = try frame.sampleBuffer()
            if let description = CMSampleBufferGetFormatDescription(sample) {
                videoSize = CMVideoFormatDescriptionGetPresentationDimensions(description,usePixelAspectRatio:true,useCleanAperture:true)
            }
            guard mailbox.isCurrent(frame.generation) else { return }
            let enqueueStartedAt = VideoTelemetry.nowMicros()
            let result = try await receiver.enqueue(CMReadySampleBuffer(unsafeBuffer: sample))
            guard mailbox.isCurrent(frame.generation) else { return }
            try checkEnqueue(result)
            if case .cancelledDueToFlush = result { return }
            if let timing = frame.timing {
                telemetry?.enqueue(generation:frame.generation,timing:timing,startMicros:enqueueStartedAt,endMicros:VideoTelemetry.nowMicros())
            }
            lastPTS = frame.presentationTime
        } catch {
            receiver.flush()
            guard mailbox.isCurrent(work.generation) else { return }
            decoderFailure?(work.generation, String(describing: error))
            onFailure(String(describing: error))
        }
    }
}

/// Coalesces decoded images instead of retaining a task (and pixel buffer) per frame.
final class PresentationMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var frame: DecodedVideoFrame?
    private var scheduled = false
    private var dirty = false
    private var wakeScheduled = false
    func reserveWake() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !wakeScheduled else { return false }
        wakeScheduled = true; return true
    }
    func finishWake() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        wakeScheduled = false; return generation
    }
    func reset(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation >= self.generation else { return false }
        self.generation = generation; frame = nil; dirty = true
        if scheduled { return false }
        scheduled = true; return true
    }
    func offer(_ image: DecodedVideoFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard image.generation == generation else { return false }
        if let frame, CMTimeCompare(image.presentationTime, frame.presentationTime) <= 0 { return false }
        frame = image; dirty = true
        if scheduled { return false }
        scheduled = true; return true
    }
    func take() -> (generation: UInt64, frame: DecodedVideoFrame?) {
        lock.lock(); defer { lock.unlock() }
        dirty = false
        let result = (generation, frame); frame = nil
        return result
    }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if dirty { return true }
        scheduled = false; return false
    }
    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return value == generation
    }
}

func checkEnqueue(_ result: AVSampleBufferVideoRenderer.Receiver.EnqueueResult) throws {
    switch result {
    case .enqueued: return
    case .cancelledDueToFlush: return
    case .enqueuedWithDecodeFailures(let errors):
        throw VideoDecoderError.unsupported("display conversion failed: \(errors)")
    case .cancelledDueToFlushRequiredToResume(let error), .cancelledDueToError(let error): throw error
    @unknown default: throw VideoDecoderError.unsupported("unknown display enqueue result")
    }
}
