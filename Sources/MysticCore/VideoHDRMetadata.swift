public import Foundation

/// Static HDR10 metadata in the byte order Core Video expects (HEVC SEI D.2.28/D.2.35).
public struct VideoHDRMetadata: Sendable, Equatable {
    public var masteringDisplay: Data?
    public var contentLightLevel: Data?
    public init(masteringDisplay: Data? = nil, contentLightLevel: Data? = nil) {
        self.masteringDisplay = masteringDisplay; self.contentLightLevel = contentLightLevel
    }
    public func merging(_ newer: VideoHDRMetadata) -> VideoHDRMetadata {
        VideoHDRMetadata(masteringDisplay: newer.masteringDisplay ?? masteringDisplay,
                         contentLightLevel: newer.contentLightLevel ?? contentLightLevel)
    }
    public static func extractNAL(from data: Data, codec: VideoCodec) throws -> VideoHDRMetadata {
        var result = VideoHDRMetadata()
        for range in AnnexB.nalUnitRanges(in: data) {
            let nal = Data(data[range])
            guard let h = nal.first else { continue }
            let type = codec.nalUnitType(h)
            guard codec == .h264 ? type == 6 : (type == 39 || type == 40) else { continue }
            let headerSize = codec == .h264 ? 1 : 2
            guard nal.count > headerSize else { throw AV1.ParseError.malformed }
            let bytes = Array(AnnexB.stripEmulationPrevention(Data(nal.dropFirst(headerSize))))
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x80 && bytes[i...].dropFirst().allSatisfy({ $0 == 0 }) { break }
                var payloadType = 0, size = 0
                while i < bytes.count, bytes[i] == 255 { payloadType += 255; i += 1 }
                guard i < bytes.count else { throw AV1.ParseError.malformed }
                payloadType += Int(bytes[i]); i += 1
                while i < bytes.count, bytes[i] == 255 { size += 255; i += 1 }
                guard i < bytes.count else { throw AV1.ParseError.malformed }
                size += Int(bytes[i]); i += 1
                guard size <= bytes.count - i else { throw AV1.ParseError.malformed }
                if payloadType == 137 {
                    guard size == 24 else { throw AV1.ParseError.malformed }
                    result.masteringDisplay = Data(bytes[i..<i+size])
                } else if payloadType == 144 {
                    guard size == 4 else { throw AV1.ParseError.malformed }
                    result.contentLightLevel = Data(bytes[i..<i+size])
                }
                i += size
            }
        }
        return result
    }
    private static func av1MasteringToHEVC(_ data: Data) throws -> Data {
        let b = Array(data)
        func value(_ offset: Int, _ count: Int) -> UInt64 {
            b[offset..<offset+count].reduce(0) { $0 << 8 | UInt64($1) }
        }
        var out = Data()
        func append(_ value: UInt64, scale: UInt64, divisor: UInt64, count: Int) throws {
            let converted = (value * scale + divisor / 2) / divisor
            guard converted < (UInt64(1) << (count * 8)) else { throw AV1.ParseError.unsupported }
            for n in (0..<count).reversed() { out.append(UInt8(truncatingIfNeeded: converted >> (n * 8))) }
        }
        for primary in [1, 2, 0] {
            for component in 0..<2 { try append(value(primary * 4 + component * 2, 2), scale: 50000, divisor: 65536, count: 2) }
        }
        for component in 0..<2 { try append(value(12 + component * 2, 2), scale: 50000, divisor: 65536, count: 2) }
        try append(value(16, 4), scale: 10000, divisor: 256, count: 4)
        try append(value(20, 4), scale: 10000, divisor: 16384, count: 4)
        return out
    }
    public static func extractAV1(from data: Data) throws -> VideoHDRMetadata {
        var result = VideoHDRMetadata()
        for unit in try AV1.units(in: data) where unit.type == 5 {
            let bytes = Array(unit.payload)
            var type: UInt64 = 0, offset = 0
            for n in 0..<8 {
                guard offset < bytes.count else { throw AV1.ParseError.malformed }
                let b = bytes[offset]; offset += 1
                type |= UInt64(b & 127) << (n * 7)
                if b & 128 == 0 { break }
                if n == 7 { throw AV1.ParseError.malformed }
            }
            if type == 1 || type == 2 {
                let size = type == 1 ? 4 : 24
                guard bytes.count == offset + size + 1, bytes.last == 0x80 else { throw AV1.ParseError.malformed }
                let payload = Data(bytes[offset..<offset+size])
                // CLL uses the same units. MDCV needs RGB -> GBR reordering and
                // conversion from AV1 fixed-point units to HEVC chromaticity/luminance units.
                if type == 1 { result.contentLightLevel = payload }
                else { result.masteringDisplay = try av1MasteringToHEVC(payload) }
            }
        }
        return result
    }
}
