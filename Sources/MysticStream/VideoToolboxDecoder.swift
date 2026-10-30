import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import MysticCore
import MysticKit

/// Consumer methods serialize on a private queue. Output closures run on decoder threads:
/// they must return promptly and must not call this decoder's lifecycle methods synchronously.
public final class VideoToolboxDecoder: VideoConsumer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mystic.VideoToolbox")
    private let completion = DecodeCompletionState()
    private let telemetry: VideoTelemetry?
    private let capabilities: VideoCapabilities
    private let output: @Sendable (DecodedVideoFrame) -> Void
    private let requestRecovery: @Sendable () -> Void
    private let resetOutput: @Sendable (UInt64) -> Void
    private let log: @Sendable (String) -> Void
    private var setupInfo: VideoSetupInfo?
    private var format: VideoFormat?
    private var session: VTDecompressionSession?
    private var compressed: CompressedVideo?
    private var recovery = VideoRecovery()
    private var origin: UInt64?
    private var running = false
    private var generation: UInt64 = 0
    private var fullRange = false
    #if DEBUG
    private var dropNextFrame = false
    #endif

    public init(capabilities: VideoCapabilities, telemetry: VideoTelemetry? = nil,
                output: @escaping @Sendable (DecodedVideoFrame) -> Void,
                requestRecovery: @escaping @Sendable () -> Void = {},
                resetOutput: @escaping @Sendable (UInt64) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.requestRecovery=requestRecovery
        self.telemetry = telemetry
        self.capabilities = capabilities; self.output = output
        self.resetOutput = resetOutput; self.log = log
    }

    @MainActor
    public convenience init(capabilities: VideoCapabilities, presenter: DisplayLayerPresenter, telemetry: VideoTelemetry? = nil,
                            requestRecovery: @escaping @Sendable () -> Void = {},
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(capabilities: capabilities, telemetry: telemetry, output: { [weak presenter] in presenter?.offer($0) },
                  requestRecovery:requestRecovery,resetOutput: { [weak presenter] in presenter?.reset(generation: $0) }, log: log)
        presenter.decoderFailure = { [weak self] generation, reason in
            if self?.completion.fail(generation:generation) == true {
                self?.resetOutput(generation &+ 1);requestRecovery();log("Presentation failed: \(reason); requesting IDR immediately")
            }
        }
    }

    deinit {
        telemetry?.activate(generation:generation &+ 1)
        completion.reset(generation: generation &+ 1)
        resetOutput(generation &+ 1)
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    public func setup(_ info: VideoSetupInfo) throws {
        try queue.sync {
            running = false; invalidate()
            setupInfo = nil; format = nil
            guard let selected = VideoFormat(rawValue: info.format), capabilities.supportedFormats & info.format != 0 else {
                throw VideoDecoderError.unsupported(capabilities.exclusionReasons[info.format] ?? "unknown format \(info.format)")
            }
            guard info.width > 0, info.height > 0, info.width <= 16384, info.height <= 16384,
                  info.fps > 0, info.chromaPacking == 0,
                  [0, 1, 2].contains(info.colorSpace), [0, 1].contains(info.colorRange),
                  (info.logicalWidth == 0 || info.logicalWidth == info.width),
                  (info.logicalHeight == 0 || info.logicalHeight == info.height) else {
                throw VideoDecoderError.unsupported("invalid geometry, color mode, or packed chroma")
            }
            setupInfo = info; format = selected
            // Nightjar COLOR_RANGE_LIMITED=0, COLOR_RANGE_FULL=1.
            fullRange = info.colorRange == 1
            log("Video setup: \(selected) \(info.width)×\(info.height) @ \(info.fps) fps, \(fullRange ? "full" : "limited") range")
        }
    }
    public func start() { queue.sync { if setupInfo != nil { running = true } } }
    public func stop() { queue.sync { running = false; invalidate() } }
    public func cleanup() { queue.sync { running = false; invalidate(); setupInfo = nil; format = nil } }

    public func submit(_ frame: VideoFrameInfo) -> FrameDisposition {
        let submittedAt = VideoTelemetry.nowMicros()
        return queue.sync { () -> FrameDisposition in
            guard running, let format, setupInfo != nil else { return .needIDR }
            #if DEBUG
            if dropNextFrame { dropNextFrame=false;return fail("simulated lost compressed frame") }
            #endif
            if completion.takeFailure() { invalidate(preserveOrigin: true) }
            guard !recovery.needsKeyFrame || frame.isKeyFrame else { return .needIDR }
            if frame.hdrActive && !format.tenBit { return fail("HDR requires a negotiated 10-bit format") }
            guard !frame.data.isEmpty, frame.data.count <= 32 * 1024 * 1024 else { return fail("empty or oversized frame") }
            do {
                // C memory belongs to the callback. Both sample storage and config own their bytes.
                let next = try CompressedVideo.make(Data(frame.data), format: format, previous: compressed)
                let changed = next.configuration != compressed?.configuration
                if changed && !frame.isKeyFrame { return fail("configuration changed outside keyframe") }
                let rebuilding = changed || session == nil || recovery.needsKeyFrame
                if rebuilding {
                    invalidate(preserveOrigin: true)
                    let dimensions = CMVideoFormatDescriptionGetDimensions(next.description)
                    guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 16384, dimensions.height <= 16384 else {
                        throw VideoDecoderError.unsupported("coded dimensions are invalid")
                    }
                    session = try hardwareSession(description: next.description, pixelFormat: format.pixelFormat(fullRange: fullRange))
                }
                guard recovery.accept(isKeyFrame: frame.isKeyFrame, hasConfiguration: true), let session else { return .needIDR }
                compressed = CompressedVideo(description: next.description, configuration: next.configuration, payload: Data(), hdrMetadata: next.hdrMetadata)
                if origin == nil { origin = frame.presentationTimeMicros }
                guard let relative = VideoTimestamp.relativeMicros(frame.presentationTimeMicros, origin: origin!) else {
                    invalidate(); log("PTS regressed or overflowed; resetting timestamp origin")
                    return .needIDR
                }
                let sample = try next.sample(pts: CMTime(value: relative, timescale: 1_000_000))
                let token = generation
                // Dropping an encoded reference frame requires IDR recovery, not just dropping display.
                guard completion.reserve(generation: token) else { return fail("decode queue is full") }
                telemetry?.submit(generation:token,hostTenthMs:frame.hostProcessingLatencyTenthMs,
                                  receiveMicros:frame.receiveTimeMicros,completeMicros:frame.enqueueTimeMicros)
                let state = completion, output = output, log = log, telemetry = telemetry, requestRecovery = requestRecovery, resetOutput = resetOutput
                let announceRecovery = rebuilding && frame.isKeyFrame
                let signalFailure: @Sendable (String) -> Void = { reason in
                    if state.fail(generation:token) { resetOutput(token &+ 1);requestRecovery();log("\(reason); requesting IDR immediately") }
                }
                let expectedPixel = format.pixelFormat(fullRange: fullRange)
                let nominalFrameRate=UInt32(setupInfo?.fps ?? 60)
                let hdr = frame.hdrActive
                let hdrMetadata = next.hdrMetadata
                let decodeStartedAt = VideoTelemetry.nowMicros()
                let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                    flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, pts, _ in
                    let decodedAt = VideoTelemetry.nowMicros()
                    guard state.complete(generation: token) else { return }
                    guard status == noErr, let image else {
                        signalFailure("\(format) decode failed (OSStatus \(status))")
                        return
                    }
                    guard CVPixelBufferGetPixelFormatType(image) == expectedPixel, CVPixelBufferGetIOSurface(image) != nil else {
                        signalFailure("\(format) output changed pixel format or has no IOSurface")
                        return
                    }
                    hdrMetadata.attach(to: image)
                    if hdr {
                        let transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil)
                        guard let transfer, CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) || CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG) else {
                            signalFailure("HDR frame missing PQ/HLG transfer attachment")
                            return
                        }
                    }
                    guard state.isCurrent(token) else { return }
                    if announceRecovery { log("Video keyframe decoded: \(format), generation \(token)") }
                    telemetry?.decode(generation:token,startMicros:decodeStartedAt,endMicros:decodedAt)
                    output(DecodedVideoFrame(pixelBuffer: image, presentationTime: pts, generation: token,
                                             timing:VideoFrameTiming(submitMicros:submittedAt,decodedMicros:decodedAt),frameRate:nominalFrameRate))
                }
                if status != noErr {
                    _ = completion.complete(generation: token)
                    return fail("\(format) submission failed (OSStatus \(status))")
                }
                return .ok
            } catch { return fail("\(format): \(error)") }
        }
    }

    /// Presentation errors are asynchronous; recovery is requested on the next engine callback.
    public func presentationFailed(_ reason: String) {
        if let token=completion.failCurrent() {
            resetOutput(token &+ 1);requestRecovery();log("Presentation failed: \(reason); requesting IDR immediately")
        }
    }

    private func fail(_ reason: String) -> FrameDisposition {
        invalidate(preserveOrigin: true); log(reason); return .needIDR
    }
    private func invalidate(preserveOrigin: Bool = false) {
        generation &+= 1
        completion.reset(generation: generation)
        telemetry?.activate(generation:generation)
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        // A lost reference does not erase validated parameter sets. Setup/cleanup still do.
        if !preserveOrigin { compressed = nil }
        recovery.invalidate()
        if !preserveOrigin {
            origin = nil
            #if DEBUG
            dropNextFrame=false
            #endif
        }
        resetOutput(generation)
    }

    #if DEBUG
    /// App-local reference-loss test. No packet filters or system network changes.
    public func simulateFrameLoss() { queue.sync { if running { dropNextFrame=true } } }
    #endif

    // Deterministic test/fixture barrier. Never called on the render or engine thread.
    func waitForFrames() { queue.sync { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) } } }
}

/// Separate from the lifecycle queue: VideoToolbox may complete synchronously during decode.
final class DecodeCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending = 0
    private var failed = false
    private var failureTaken = false
    private var active = false
    func reset(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; pending = 0; failed = false; failureTaken=false; active=false
    }
    func reserve(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation, !failed, pending < 3 else { return false }
        active=true;pending += 1; return true
    }
    func complete(generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation,active,pending > 0 else { return false }
        pending -= 1; return true
    }
    @discardableResult
    func fail(generation: UInt64) -> Bool {
        lock.lock();defer { lock.unlock() }
        guard self.generation == generation,active,!failed else { return false }
        failed=true;return true
    }
    @discardableResult
    func failCurrent() -> UInt64? {
        lock.lock();defer { lock.unlock() }
        guard active,!failed else { return nil };failed=true;return generation
    }
    func takeFailure() -> Bool {
        lock.lock();defer { lock.unlock() }
        guard failed,!failureTaken else { return false };failureTaken=true;return true
    }
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock();defer { lock.unlock() };return self.generation == generation && active && !failed
    }
}
