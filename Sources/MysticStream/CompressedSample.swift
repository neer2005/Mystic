import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import MysticCore

/// One access unit ready for VideoToolbox. The engine's bytes are only borrowed for the length
/// of its callback, and this runs for every frame of the stream, so they are walked once and
/// copied once, straight into the block buffer the decoder reads; only the few small units that
/// describe the stream (parameter sets, HDR metadata) are copied besides.
struct CompressedVideo {
    let description: CMVideoFormatDescription
    let configuration: Data
    /// The access unit as VideoToolbox takes it: AVCC for H.264 and HEVC, AV1 as it came. Nil in
    /// the copy a decoder keeps for the next frame's `previous`, which needs no picture.
    let payload: CMBlockBuffer?
    var hdrMetadata = VideoHDRMetadata()

    /// What the next frame needs of this one: its configuration, without its picture.
    var withoutPayload: CompressedVideo {
        CompressedVideo(description: description, configuration: configuration, payload: nil, hdrMetadata: hdrMetadata)
    }

    static func make(_ data: Data, format: VideoFormat, previous: CompressedVideo?) throws -> CompressedVideo {
        try data.withUnsafeBytes { try make($0, format: format, previous: previous) }
    }

    static func make(_ raw: UnsafeRawBufferPointer, format: VideoFormat, previous: CompressedVideo?) throws -> CompressedVideo {
        var next: CompressedVideo
        let metadata: VideoHDRMetadata
        if format.isAV1 {
            // Validate every access unit, including non-key frames.
            let units = try AV1.unitRanges(in: raw)
            guard !units.isEmpty else { throw VideoDecoderError.invalidSample("empty AV1 access unit") }
            let stream = try av1Stream(raw, units: units, format: format) ?? inherited(previous)
            next = CompressedVideo(description: stream.description, configuration: stream.configuration,
                                   payload: try block(length: raw.count) { $0.copyMemory(from: raw) })
            metadata = try VideoHDRMetadata.extractAV1(from: raw, units: units)
        } else {
            let codec: VideoCodec = format.isH264 ? .h264 : .hevc
            let ranges = AnnexB.nalUnitRanges(in: raw)
            let stream = try nalStream(raw, ranges: ranges, codec: codec, format: format) ?? inherited(previous)
            guard !ranges.isEmpty else { throw VideoDecoderError.invalidSample("empty access unit") }
            next = CompressedVideo(description: stream.description, configuration: stream.configuration,
                                   payload: try block(length: AnnexB.avccLength(ranges: ranges)) { AnnexB.writeAVCC(from: raw, ranges: ranges, to: $0) })
            metadata = try VideoHDRMetadata.extractNAL(from: raw, ranges: ranges, codec: codec)
        }
        next.hdrMetadata = (previous?.configuration == next.configuration ? previous?.hdrMetadata : nil)?.merging(metadata) ?? metadata
        return next
    }

    private typealias Stream = (description: CMVideoFormatDescription, configuration: Data)
    /// A frame without its own configuration continues the last one's.
    private static func inherited(_ previous: CompressedVideo?) throws -> Stream {
        guard let previous else { throw VideoDecoderError.invalidSample("waiting for complete keyframe configuration") }
        return (previous.description, previous.configuration)
    }

    /// The stream a sequence header in this access unit describes; nil when it has none.
    private static func av1Stream(_ raw: UnsafeRawBufferPointer, units: [AV1.UnitRange], format: VideoFormat) throws -> Stream? {
        guard let config = try AV1.configuration(in: raw, units: units) else { return nil }
        guard config.profile == (format.chroma444 ? 1 : 0),
              config.bitDepth == (format.tenBit ? 10 : 8), !config.monochrome else {
            throw VideoDecoderError.invalidSample("AV1 sequence disagrees with negotiated profile")
        }
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C": config.record],
            kCMFormatDescriptionExtension_FullRangeVideo: config.fullRange,
        ]
        func color(_ value: Int, key: CFString, choices: [Int: CFString]) throws {
            if value == 2 { return } // Unspecified: do not invent a colorimetry tag.
            guard let name = choices[value] else { throw VideoDecoderError.unsupported("AV1 colorimetry \(value) for \(key)") }
            extensions[key] = name
        }
        try color(config.colorPrimaries, key: kCMFormatDescriptionExtension_ColorPrimaries,
            choices: [1: kCMFormatDescriptionColorPrimaries_ITU_R_709_2, 5: kCMFormatDescriptionColorPrimaries_EBU_3213,
                      6: kCMFormatDescriptionColorPrimaries_SMPTE_C, 9: kCMFormatDescriptionColorPrimaries_ITU_R_2020])
        try color(config.transferFunction, key: kCMFormatDescriptionExtension_TransferFunction,
            choices: [1: kCMFormatDescriptionTransferFunction_ITU_R_709_2, 6: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                      13: kCMFormatDescriptionTransferFunction_sRGB, 14: kCMFormatDescriptionTransferFunction_ITU_R_2020,
                      15: kCMFormatDescriptionTransferFunction_ITU_R_2020, 16: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                      18: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG])
        if config.matrix != 0 { // Identity RGB has no YCbCr matrix.
            try color(config.matrix, key: kCMFormatDescriptionExtension_YCbCrMatrix,
                choices: [1: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, 5: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4,
                          6: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4, 9: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020])
        }
        var desc: CMFormatDescription?
        try checked(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
            width: Int32(config.width), height: Int32(config.height), extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc), "AV1 format description")
        guard let desc else { throw VideoDecoderError.invalidSample("missing AV1 format description") }
        return (desc, config.record)
    }

    /// The stream the parameter sets in this access unit describe; nil when it has none.
    private static func nalStream(_ raw: UnsafeRawBufferPointer, ranges: [Range<Int>], codec: VideoCodec, format: VideoFormat) throws -> Stream? {
        let parameterTypes: Set<UInt8> = format.isH264 ? [7,8] : [32,33,34]
        let hasParameterSets = ranges.contains { parameterTypes.contains(codec.nalUnitType(raw[$0.lowerBound])) }
        guard let sets = ParameterSets.extract(from: raw, ranges: ranges, codec: codec) else {
            if hasParameterSets { throw VideoDecoderError.invalidSample("incomplete parameter sets") }
            return nil
        }
        let properties = try NALConfiguration.parse(sps: sets.sps, codec: codec)
        guard properties.bitDepth == (format.tenBit ? 10 : 8), properties.chroma444 == format.chroma444 else {
            throw VideoDecoderError.invalidSample("NAL sequence disagrees with negotiated profile")
        }
        let units = (sets.vps.map { [$0] } ?? []) + [sets.sps, sets.pps]
        // Keep all backing bytes alive throughout the pointer-based CoreMedia call.
        let storage = units.map { unit -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: unit.count)
            unit.copyBytes(to: p, count: unit.count)
            return p
        }
        defer { storage.forEach { $0.deallocate() } }
        let pointers = storage.map { UnsafePointer($0) }
        let sizes = units.map(\.count)
        var desc: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                if format.isH264 {
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: units.count, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                }
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: units.count, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            }
        }
        try checked(status, "\(format) parameter sets")
        guard let desc else { throw VideoDecoderError.invalidSample("missing NAL format description") }
        var signature = Data()
        for unit in units {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { signature.append(contentsOf: $0) }
            signature.append(unit)
        }
        return (desc, signature)
    }

    /// A block buffer of `length` bytes that owns its memory, filled in place by `fill`.
    private static func block(length: Int, fill: (UnsafeMutableRawBufferPointer) -> Void) throws -> CMBlockBuffer {
        guard length > 0 else { throw VideoDecoderError.invalidSample("empty access unit") }
        var block: CMBlockBuffer?
        try checked(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), "allocate compressed block")
        guard let block else { throw VideoDecoderError.invalidSample("missing block") }
        var memory: UnsafeMutablePointer<CChar>?
        var contiguous = 0
        try checked(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: nil,
            dataPointerOut: &memory), "compressed block memory")
        guard let memory, contiguous == length else { throw VideoDecoderError.invalidSample("compressed block is not contiguous") }
        fill(UnsafeMutableRawBufferPointer(start: memory, count: length))
        return block
    }

    func sample(pts: CMTime) throws -> CMSampleBuffer {
        guard let payload else { throw VideoDecoderError.invalidSample("access unit has no picture") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = CMBlockBufferGetDataLength(payload)
        var sample: CMSampleBuffer?
        try checked(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: payload,
            formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "compressed sample buffer")
        guard let sample else { throw VideoDecoderError.invalidSample("missing sample") }
        return sample
    }
}

func hardwareSession(description: CMVideoFormatDescription, pixelFormat: OSType) throws -> VTDecompressionSession {
    var session: VTDecompressionSession?
    try checked(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
        decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
        imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                               kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        outputCallback: nil, decompressionSessionOut: &session), "create hardware decompression session")
    guard let session else { throw VideoDecoderError.invalidSample("missing decompression session") }
    var hardware: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                      allocator: kCFAllocatorDefault, valueOut: &hardware)
    guard status == noErr, (hardware?.takeRetainedValue() as? Bool) == true else {
        VTDecompressionSessionInvalidate(session)
        throw VideoDecoderError.unsupported("hardware decoder was not selected")
    }
    _ = VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    return session
}
