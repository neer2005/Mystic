import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import VideoToolbox

/// Results are specific to this Mac, OS, and the bundled 64x64 profile fixtures.
/// Session creation still validates the actual stream configuration at its resolution.
public struct VideoCapabilities: Sendable {
    public let supportedFormats: UInt32
    public let exclusionReasons: [UInt32: String]

    /// Decode and enqueue each profile, rather than inferring profile support from a codec Boolean.
    /// Call once when initializing the streaming subsystem; this performs hardware work.
    @MainActor
    public static func probe() async -> VideoCapabilities {
        var mask: UInt32 = 0
        var reasons: [UInt32: String] = [:]
        for format in VideoFormat.allCases {
            do {
                guard VTIsHardwareDecodeSupported(format.codec) else {
                    throw VideoDecoderError.unsupported("no hardware \(format) decoder")
                }
                let frame = try decodeFixture(format)
                let layer = AVSampleBufferDisplayLayer()
                layer.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
                let synchronizer = AVSampleBufferRenderSynchronizer()
                let receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
                synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
                synchronizer.setRate(1, time: .zero)
                try checkEnqueue(receiver.enqueueImmediately(immediateSample(frame)))
                // Allow the renderer to report asynchronous conversion failures.
                for _ in 0..<20 {
                    if layer.isReadyForDisplay { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                defer { receiver.flush() }
                guard layer.isReadyForDisplay else {
                    throw VideoDecoderError.unsupported("display layer did not become ready")
                }
                mask |= format.rawValue
            } catch { reasons[format.rawValue] = String(describing: error) }
        }
        for bit: UInt32 in [0x10000, 0x20000, 0x40000, 0x80000] {
            reasons[bit] = "PyroWave requires the future Metal backend"
        }
        return VideoCapabilities(supportedFormats: mask, exclusionReasons: reasons)
    }

    static func fixture(_ format: VideoFormat) throws -> Data {
        guard let url = Bundle.module.url(forResource: format.fixtureName, withExtension: "bin", subdirectory: "Fixtures") else {
            throw VideoDecoderError.invalidSample("missing bundled \(format) probe fixture")
        }
        return try Data(contentsOf: url)
    }

    static func decodeFixture(_ format: VideoFormat) throws -> DecodedVideoFrame {
        let compressed = try CompressedVideo.make(fixture(format), format: format, previous: nil)
        let session = try hardwareSession(description: compressed.description, pixelFormat: format.pixelFormat(fullRange: false))
        defer { VTDecompressionSessionInvalidate(session) }
        let result = ProbeResult()
        try checked(VTDecompressionSessionDecodeFrame(session,
            sampleBuffer: compressed.sample(pts: CMTime(value: 1234567, timescale: 1_000_000)), flags: [], infoFlagsOut: nil) {
                status, _, image, pts, _ in result.store(status: status, image: image, pts: pts)
            }, "\(format) probe submission")
        try checked(VTDecompressionSessionWaitForAsynchronousFrames(session), "\(format) probe completion")
        let frame = try result.frame()
        compressed.hdrMetadata.attach(to: frame.pixelBuffer)
        guard CVPixelBufferGetWidth(frame.pixelBuffer) == 64, CVPixelBufferGetHeight(frame.pixelBuffer) == 64,
              CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == format.pixelFormat(fullRange: false),
              CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil,
              CMTimeCompare(frame.presentationTime, CMTime(value: 1234567, timescale: 1_000_000)) == 0 else {
            throw VideoDecoderError.unsupported("\(format) output geometry, chroma, depth, surface, or PTS mismatch")
        }
        let expectedTransfer = format.tenBit ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2
        guard let transfer = CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
              CFEqual(transfer, expectedTransfer) else {
            throw VideoDecoderError.unsupported("\(format) output lost color transfer metadata")
        }
        return frame
    }
}

private final class ProbeResult: @unchecked Sendable {
    let lock = NSLock()
    var image: CVPixelBuffer?
    var status: OSStatus = -1
    var pts: CMTime = .invalid
    func store(status: OSStatus, image: CVPixelBuffer?, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }; self.status = status; self.image = image; self.pts = pts
    }
    func frame() throws -> DecodedVideoFrame {
        lock.lock(); defer { lock.unlock() }
        try checked(status, "probe decode")
        guard let image else { throw VideoDecoderError.invalidSample("probe produced no image") }
        return DecodedVideoFrame(pixelBuffer: image, presentationTime: pts, generation: 0)
    }
}

private func immediateSample(_ frame: DecodedVideoFrame) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
    let sample = try frame.sampleBuffer()
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return CMReadySampleBuffer(unsafeBuffer: sample)
}
