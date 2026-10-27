import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import MysticCore

struct CompressedVideo {
    let description: CMVideoFormatDescription
    let configuration: Data
    let payload: Data
    var hdrMetadata = VideoHDRMetadata()

    static func make(_ data: Data, format: VideoFormat, previous: CompressedVideo?) throws -> CompressedVideo {
        var next = try build(data, format: format, previous: previous)
        let metadata = try format.isAV1 ? VideoHDRMetadata.extractAV1(from: data) : VideoHDRMetadata.extractNAL(from: data, codec: format.isH264 ? .h264 : .hevc)
        next.hdrMetadata = (previous?.configuration == next.configuration ? previous?.hdrMetadata : nil)?.merging(metadata) ?? metadata
        return next
    }

    private static func build(_ data: Data, format: VideoFormat, previous: CompressedVideo?) throws -> CompressedVideo {
        if format.isAV1 {
            // Validate every access unit, including non-key frames.
            guard !(try AV1.units(in: data)).isEmpty else { throw VideoDecoderError.invalidSample("empty AV1 access unit") }
            if let config = try AV1.configuration(in: data) {
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
                return CompressedVideo(description: desc, configuration: config.record, payload: data)
            }
        } else {
            let codec: VideoCodec = format.isH264 ? .h264 : .hevc
            if let sets = ParameterSets.extract(from: data, codec: codec) {
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
                return CompressedVideo(description: desc, configuration: signature, payload: AnnexB.avccSample(from: data))
            }
        }
        guard let previous else { throw VideoDecoderError.invalidSample("waiting for complete keyframe configuration") }
        let payload = format.isAV1 ? data : AnnexB.avccSample(from: data)
        guard !payload.isEmpty else { throw VideoDecoderError.invalidSample("empty access unit") }
        return CompressedVideo(description: previous.description, configuration: previous.configuration, payload: payload)
    }

    func sample(pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        try checked(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block), "allocate compressed block")
        guard let block else { throw VideoDecoderError.invalidSample("missing block") }
        try payload.withUnsafeBytes { bytes in
            try checked(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count), "copy compressed bytes")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        try checked(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
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
