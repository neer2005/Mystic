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

    static func nalUnitRanges(in raw: UnsafeRawBufferPointer) -> [Range<Int>] {
        let bytes = raw.bindMemory(to: UInt8.self)
        let count = bytes.count
        guard count >= 3 else { return [] }

        var ranges: [Range<Int>] = []
        var payloadStart: Int?
        var index = 0

        while index + 2 < count {
            let isStartCode = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            guard isStartCode else {
                index += 1
                continue
            }

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
            index += 3
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
        var vps: Data?
        var sps: Data?
        var pps: Data?

        for range in AnnexB.nalUnitRanges(in: data) {
            let nal = data[range]
            guard let header = nal.first else { continue }
            let type = codec.nalUnitType(header)

            switch (codec, type) {
            case (.hevc, 32): if vps == nil { vps = Data(nal) }
            case (.h264, 7), (.hevc, 33): if sps == nil { sps = Data(nal) }
            case (.h264, 8), (.hevc, 34): if pps == nil { pps = Data(nal) }
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
