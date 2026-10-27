import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

/// Exact VIDEO_FORMAT_* values from Nightjar f449b5d, protocol/client/src/sdp.rs.
public enum VideoFormat: UInt32, CaseIterable, Sendable {
    case h264 = 0x0001, h264444 = 0x0004
    case hevc = 0x0100, hevc10 = 0x0200, hevc444 = 0x0400, hevc10444 = 0x0800
    case av1 = 0x1000, av110 = 0x2000, av1444 = 0x4000, av110444 = 0x8000
    public var isAV1: Bool { rawValue & 0xF000 != 0 }
    public var isH264: Bool { rawValue & 0xF != 0 }
    public var tenBit: Bool { rawValue & 0xAA00 != 0 }
    public var chroma444: Bool { rawValue & 0xCC04 != 0 }
    var codec: CMVideoCodecType { isAV1 ? kCMVideoCodecType_AV1 : (isH264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC) }
    var fixtureName: String {
        switch self {
        case .h264: "h264"
        case .h264444: "h264-444"
        case .hevc: "hevc"
        case .hevc10: "hevc-10"
        case .hevc444: "hevc-444"
        case .hevc10444: "hevc-10-444"
        case .av1: "av1"
        case .av110: "av1-10"
        case .av1444: "av1-444"
        case .av110444: "av1-10-444"
        }
    }
    func pixelFormat(fullRange: Bool) -> OSType {
        if chroma444 {
            if tenBit { return fullRange ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange }
            return fullRange ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        }
        if tenBit { return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
        return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}

public enum VideoDecoderError: Error, CustomStringConvertible {
    case unsupported(String)
    case invalidSample(String)
    case apple(String, OSStatus)
    public var description: String {
        switch self {
        case .unsupported(let reason): "Unsupported video: \(reason)"
        case .invalidSample(let reason): "Invalid video sample: \(reason)"
        case .apple(let operation, let code): "\(operation) failed (OSStatus \(code))"
        }
    }
}

func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw VideoDecoderError.apple(operation, status) }
}
