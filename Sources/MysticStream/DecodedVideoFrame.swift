import CoreMedia
import CoreVideo
import MysticCore

/// Immutable handoff. Core Video retains the IOSurface; no CPU pixel copy is performed.
public struct DecodedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let generation: UInt64
    public let timing: VideoFrameTiming?
    public let frameRate: UInt32
    public init(pixelBuffer: CVPixelBuffer,presentationTime: CMTime,generation: UInt64,timing: VideoFrameTiming? = nil,frameRate: UInt32 = 60) {
        self.pixelBuffer=pixelBuffer;self.presentationTime=presentationTime;self.generation=generation;self.timing=timing;self.frameRate=frameRate
    }

    func sampleBuffer(presentationTime: CMTime? = nil) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        try checked(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescriptionOut: &description), "decoded image description")
        guard let description else { throw VideoDecoderError.invalidSample("missing image description") }
        var timing = CMSampleTimingInfo(duration: (1...1000).contains(frameRate) ? CMTime(value:1,timescale:Int32(frameRate)) : .invalid, presentationTimeStamp: presentationTime ?? self.presentationTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try checked(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample), "decoded image sample")
        guard let sample else { throw VideoDecoderError.invalidSample("missing image sample") }
        return sample
    }
}

/// HDR must be interpreted from source tags, never from the user's launch preference alone.
func validateHDRImage(_ image: CVPixelBuffer) throws {
    let transfer=CVBufferCopyAttachment(image,kCVImageBufferTransferFunctionKey,nil)
    guard let transfer,CFEqual(transfer,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
            CFEqual(transfer,kCVImageBufferTransferFunction_ITU_R_2100_HLG) else {
        throw VideoDecoderError.invalidSample("HDR frame missing PQ/HLG transfer attachment")
    }
    guard CVBufferCopyAttachment(image,kCVImageBufferColorPrimariesKey,nil) != nil,
          CVBufferCopyAttachment(image,kCVImageBufferYCbCrMatrixKey,nil) != nil else {
        throw VideoDecoderError.invalidSample("HDR frame missing color primaries or YCbCr matrix")
    }
}

extension VideoHDRMetadata {
    func attach(to image: CVPixelBuffer) {
        if let masteringDisplay {
            CVBufferSetAttachment(image, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay as CFData, .shouldPropagate)
        }
        if let contentLightLevel {
            CVBufferSetAttachment(image, kCVImageBufferContentLightLevelInfoKey, contentLightLevel as CFData, .shouldPropagate)
        }
    }
}
