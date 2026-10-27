public import Foundation

/// The profile properties that must not be silently converted to a lower-fidelity output.
public struct NALConfiguration: Sendable, Equatable {
    public let bitDepth: Int
    public let chroma444: Bool

    public static func parse(sps: Data, codec: VideoCodec) throws -> NALConfiguration {
        var r = NALBits(AnnexB.stripEmulationPrevention(sps))
        var chroma = 1, depth = 8
        switch codec {
        case .h264:
            guard try r.read(8) & 0x9F == 7 else { throw AV1.ParseError.malformed }
            let profile = try r.read(8)
            _ = try r.read(16); _ = try r.ue()
            if [100,110,122,244,44,83,86,118,128,138,139,134,135].contains(profile) {
                chroma = try r.ue()
                if chroma == 3 { guard try r.read(1) == 0 else { throw AV1.ParseError.unsupported } }
                depth = try r.ue() + 8
                guard try r.ue() + 8 == depth else { throw AV1.ParseError.unsupported }
            }
        case .hevc:
            guard try r.read(8) & 0xFE == 0x42 else { throw AV1.ParseError.malformed }
            _ = try r.read(8); _ = try r.read(4)
            let sublayers = try r.read(3); _ = try r.read(1)
            try r.skip(96) // general_profile_tier_level
            var profiles: [Int] = [], levels: [Int] = []
            for _ in 0..<sublayers { profiles.append(try r.read(1)); levels.append(try r.read(1)) }
            if sublayers > 0 { try r.skip((8 - sublayers) * 2) }
            for i in 0..<sublayers {
                if profiles[i] == 1 { try r.skip(88) }
                if levels[i] == 1 { try r.skip(8) }
            }
            _ = try r.ue(); chroma = try r.ue()
            if chroma == 3 { guard try r.read(1) == 0 else { throw AV1.ParseError.unsupported } }
            _ = try r.ue(); _ = try r.ue()
            if try r.read(1) == 1 { for _ in 0..<4 { _ = try r.ue() } }
            depth = try r.ue() + 8
            guard try r.ue() + 8 == depth else { throw AV1.ParseError.unsupported }
        }
        guard [1,3].contains(chroma), [8,10].contains(depth) else { throw AV1.ParseError.unsupported }
        return NALConfiguration(bitDepth: depth, chroma444: chroma == 3)
    }
}

private struct NALBits {
    let b: [UInt8]
    var i = 0
    init(_ data: Data) { b = Array(data) }
    mutating func skip(_ n: Int) throws {
        guard n >= 0, n <= b.count * 8 - i else { throw AV1.ParseError.malformed }
        i += n
    }
    mutating func read(_ n: Int) throws -> Int {
        guard n >= 0, n <= 32, n <= b.count * 8 - i else { throw AV1.ParseError.malformed }
        var v = 0
        for _ in 0..<n { v = v << 1 | Int((b[i / 8] >> (7 - i % 8)) & 1); i += 1 }
        return v
    }
    mutating func ue() throws -> Int {
        var n = 0
        while try read(1) == 0 { n += 1; guard n < 24 else { throw AV1.ParseError.malformed } }
        return (1 << n) - 1 + (try read(n))
    }
}
