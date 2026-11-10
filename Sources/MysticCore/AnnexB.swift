public import Foundation

/// Which codec the host negotiated. The two differ in NAL header layout, so the parser needs
/// to be told rather than guessing.
public enum VideoCodec: Sendable, Equatable {
    case h264
    case hevc

    /// H.264 uses the low 5 bits of the first byte; HEVC uses bits 1–6 of the first byte.
    public func nalUnitType(_ header: UInt8) -> UInt8 {
        switch self {
        case .h264: return header & 0x1F
        case .hevc: return (header >> 1) & 0x3F
        }
    }
}

/// Annex B parsing and conversion for the compressed frames the engine hands over.
///
/// The engine delivers Annex B (start-code delimited). VideoToolbox wants an AVCC sample — a
/// 4-byte big-endian length per NAL — plus a format description built from the raw parameter
/// sets. This type does that conversion and nothing else, so it can be tested without a
/// decoder.
public enum AnnexB {
    /// Ranges of NAL units within `data`, excluding the start codes.
    ///
    /// Handles 3-byte (`00 00 01`) and 4-byte (`00 00 00 01`) prefixes, including the case
    /// where a 4-byte prefix follows a payload: the extra zero is trimmed so it does not leak
    /// into the preceding NAL.
    public static func nalUnitRanges(in data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { raw in
            nalUnitRanges(in: raw)
        }
    }

    /// The same, over bytes that are only borrowed, such as the engine's frame during its
    /// callback. This runs once for every frame of the stream, so it looks for a start code's
    /// final `01` with `memchr` rather than comparing three bytes at every offset.
    public static func nalUnitRanges(in raw: UnsafeRawBufferPointer) -> [Range<Int>] {
        let count = raw.count
        guard count >= 3, let base = raw.baseAddress else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var ranges: [Range<Int>] = []
        var payloadStart: Int?
        // The earliest offset the next start code may begin at.
        var search = 0

        while search + 2 < count {
            guard let found = memchr(base + search + 2, 1, count - search - 2) else { break }
            let one = base.distance(to: UnsafeRawPointer(found))
            guard bytes[one - 1] == 0, bytes[one - 2] == 0 else {
                search = one - 1
                continue
            }
            let index = one - 2

            if let start = payloadStart {
                var end = index
                // A 4-byte prefix means the byte before `00 00 01` belongs to it.
                if end > start, bytes[end - 1] == 0 {
                    end -= 1
                }
                if end > start {
                    ranges.append(start..<end)
                }
            }
            payloadStart = index + 3
            search = index + 3
        }

        if let start = payloadStart, start < count {
            var end = count
            while end > start, bytes[end - 1] == 0 {
                end -= 1
            }
            if end > start {
                ranges.append(start..<end)
            }
        }

        return ranges
    }

    /// Rewrites an Annex B frame as an AVCC sample: every start code becomes a 4-byte
    /// big-endian length. VideoToolbox decodes this form.
    public static func avccSample(from data: Data) -> Data {
        let ranges = nalUnitRanges(in: data)
        guard !ranges.isEmpty else { return Data() }

        var out = Data(capacity: data.count)
        for range in ranges {
            let length = UInt32(range.count)
            out.append(UInt8(truncatingIfNeeded: length >> 24))
            out.append(UInt8(truncatingIfNeeded: length >> 16))
            out.append(UInt8(truncatingIfNeeded: length >> 8))
            out.append(UInt8(truncatingIfNeeded: length))
            out.append(data[range])
        }
        return out
    }

    /// The size of the AVCC sample `writeAVCC` makes of these units.
    public static func avccLength(ranges: [Range<Int>]) -> Int {
        ranges.reduce(0) { $0 + 4 + $1.count }
    }

    /// Writes the units of `raw` as an AVCC sample straight into `out`, which holds exactly
    /// `avccLength(ranges:)` bytes: the frame's one copy on its way to the decoder.
    public static func writeAVCC(from raw: UnsafeRawBufferPointer, ranges: [Range<Int>], to out: UnsafeMutableRawBufferPointer) {
        precondition(out.count == avccLength(ranges: ranges), "AVCC destination has the wrong size")
        var offset = 0
        for range in ranges {
            out.storeBytes(of: UInt32(range.count).bigEndian, toByteOffset: offset, as: UInt32.self)
            out.baseAddress!.advanced(by: offset + 4).copyMemory(from: raw.baseAddress!.advanced(by: range.lowerBound), byteCount: range.count)
            offset += 4 + range.count
        }
    }

    /// Removes emulation prevention bytes (`00 00 03` → `00 00`) for bitstream syntax inspection.
    /// Do not use this on NAL units passed to VideoToolbox.
    public static func stripEmulationPrevention(_ nal: Data) -> Data {
        var out = Data(capacity: nal.count)
        var zeros = 0
        for byte in nal {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

/// The parameter sets a decoder needs before it can decode anything.
public struct ParameterSets: Sendable, Equatable {
    public var vps: Data?
    public var sps: Data
    public var pps: Data

    /// Extracts the first VPS/SPS/PPS from a keyframe.
    ///
    /// Returns nil when the frame does not carry a complete set — which is the signal that the
    /// caller must ask the host for a key frame rather than guess.
    public static func extract(from data: Data, codec: VideoCodec) -> ParameterSets? {
        data.withUnsafeBytes { extract(from: $0, ranges: AnnexB.nalUnitRanges(in: $0), codec: codec) }
    }

    /// The same, from units already found in borrowed bytes; only the sets themselves are copied.
    public static func extract(from raw: UnsafeRawBufferPointer, ranges: [Range<Int>], codec: VideoCodec) -> ParameterSets? {
        var vps: Data?
        var sps: Data?
        var pps: Data?

        for range in ranges {
            let type = codec.nalUnitType(raw[range.lowerBound])
            func unit() -> Data { Data(UnsafeRawBufferPointer(rebasing: raw[range])) }

            switch (codec, type) {
            case (.hevc, 32): if vps == nil { vps = unit() }
            case (.h264, 7), (.hevc, 33): if sps == nil { sps = unit() }
            case (.h264, 8), (.hevc, 34): if pps == nil { pps = unit() }
            default: continue
            }
        }

        guard let sps, let pps, codec != .hevc || vps != nil else { return nil }
        return ParameterSets(vps: vps, sps: sps, pps: pps)
    }

    public init(vps: Data? = nil, sps: Data, pps: Data) {
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }
}
