public import Foundation

/// AV1 low-overhead OBU framing and av1C configuration (AOM AV1/ISOBMFF specifications).
/// No unbounded reads, allocations from declared lengths, or guessing from codec flags.
public enum AV1 {
    public enum ParseError: Error, Equatable { case malformed, unsupported }
    public struct OBU: Sendable {
        public let type: UInt8
        public let bytes: Data
        public let payload: Data
    }
    public static func units(in data: Data) throws -> [OBU] {
        guard data.count <= 32 * 1024 * 1024 else { throw ParseError.malformed }
        let b = Array(data)
        var i = 0
        var out: [OBU] = []
        while i < b.count {
            guard out.count < 4096 else { throw ParseError.malformed }
            let start = i, h = b[i]; i += 1
            guard h & 0x81 == 0, h & 2 != 0 else { throw ParseError.malformed }
            let type = (h >> 3) & 15
            guard type > 0, type <= 8 || type == 15 else { throw ParseError.malformed }
            if h & 4 != 0 {
                guard i < b.count, b[i] & 7 == 0 else { throw ParseError.malformed }
                i += 1
            }
            var size: UInt64 = 0
            var ended = false
            for n in 0..<8 {
                guard i < b.count else { throw ParseError.malformed }
                let v = b[i]; i += 1
                size |= UInt64(v & 127) << (7 * n)
                if v & 128 == 0 { ended = true; break }
            }
            guard ended, size <= UInt64(b.count - i) else { throw ParseError.malformed }
            let end = i + Int(size)
            out.append(OBU(type: type, bytes: Data(b[start..<end]), payload: Data(b[i..<end])))
            i = end
        }
        return out
    }

    public struct Configuration: Sendable, Equatable {
        public let record: Data
        public let profile: Int
        public let bitDepth: Int
        public let chroma444: Bool
        public let colorPrimaries: Int
        public let transferFunction: Int
        public let matrix: Int
        public let fullRange: Bool
        public let monochrome: Bool
        public let width: Int
        public let height: Int
    }

    public static func configuration(in sample: Data) throws -> Configuration? {
        guard let sequence = try units(in: sample).first(where: { $0.type == 1 }) else { return nil }
        var r = Bits(sequence.payload)
        let profile = try r.read(3)
        guard profile <= 2 else { throw ParseError.malformed }
        let still = try r.read(1), reduced = try r.read(1)
        guard reduced == 0 || still == 1 else { throw ParseError.malformed }
        var level = 0, tier = 0
        if reduced == 1 { level = try r.read(5) }
        else {
            let timing = try r.read(1)
            var model = 0, delayLength = 0
            if timing == 1 {
                guard try r.read(32) != 0, try r.read(32) != 0 else { throw ParseError.malformed }
                if try r.read(1) == 1 { _ = try r.uvlc() }
                model = try r.read(1)
                if model == 1 {
                    delayLength = try r.read(5) + 1
                    _ = try r.read(32); _ = try r.read(5); _ = try r.read(5)
                }
            }
            let initialDelay = try r.read(1)
            let count = try r.read(5) + 1
            for n in 0..<count {
                _ = try r.read(12)
                let l = try r.read(5), t = l > 7 ? try r.read(1) : 0
                if n == 0 { level = l; tier = t }
                if model == 1, try r.read(1) == 1 {
                    _ = try r.read(delayLength); _ = try r.read(delayLength); _ = try r.read(1)
                }
                if initialDelay == 1, try r.read(1) == 1 { _ = try r.read(4) }
            }
        }
        let wb = try r.read(4) + 1, hb = try r.read(4) + 1
        let width = try r.read(wb) + 1, height = try r.read(hb) + 1
        if reduced == 0, try r.read(1) == 1 { _ = try r.read(4); _ = try r.read(3) }
        _ = try r.read(3)
        if reduced == 0 {
            _ = try r.read(4)
            let order = try r.read(1)
            if order == 1 { _ = try r.read(2) }
            let chooseScreen = try r.read(1)
            let screen = chooseScreen == 1 ? 2 : try r.read(1)
            if screen > 0, try r.read(1) == 0 { _ = try r.read(1) }
            if order == 1 { _ = try r.read(3) }
        }
        _ = try r.read(3)
        let high = try r.read(1)
        let twelve = profile == 2 && high == 1 ? try r.read(1) : 0
        let depth = twelve == 1 ? 12 : (high == 1 ? 10 : 8)
        let mono = profile == 1 ? 0 : try r.read(1)
        var primaries = 2, transfer = 2, matrix = 2
        if try r.read(1) == 1 {
            primaries = try r.read(8); transfer = try r.read(8); matrix = try r.read(8)
        }
        var sx = 0, sy = 0, position = 0, fullRange = 1
        if mono == 1 {
            fullRange = try r.read(1); sx = 1; sy = 1
        } else {
            if !(primaries == 1 && transfer == 13 && matrix == 0) {
                fullRange = try r.read(1)
                if profile == 0 { sx = 1; sy = 1 }
                else if profile == 2 {
                    sx = depth == 12 ? try r.read(1) : 1
                    sy = depth == 12 && sx == 1 ? try r.read(1) : 0
                }
                if sx == 1 && sy == 1 { position = try r.read(2) }
            }
            _ = try r.read(1)
        }
        _ = try r.read(1) // film_grain_params_present
        guard try r.read(1) == 1 else { throw ParseError.malformed } // trailing_one_bit
        while r.remaining > 0 { guard try r.read(1) == 0 else { throw ParseError.malformed } }
        guard position <= 2 else { throw ParseError.malformed }
        var record = Data([0x81, UInt8(profile << 5 | level),
            UInt8(tier << 7 | high << 6 | twelve << 5 | mono << 4 | sx << 3 | sy << 2 | position), 0])
        record.append(sequence.bytes)
        return Configuration(record: record, profile: profile, bitDepth: depth,
                             chroma444: sx == 0 && sy == 0, colorPrimaries: primaries,
                             transferFunction: transfer, matrix: matrix, fullRange: fullRange == 1,
                             monochrome: mono == 1, width: width, height: height)
    }

    private struct Bits {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        var remaining: Int { bytes.count * 8 - offset }
        mutating func read(_ n: Int) throws -> Int {
            guard n >= 0, n <= 32, n <= remaining else { throw ParseError.malformed }
            var value = 0
            for _ in 0..<n {
                value = value << 1 | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
        mutating func uvlc() throws -> Int {
            var zeros = 0
            while try read(1) == 0 { zeros += 1; guard zeros < 32 else { throw ParseError.malformed } }
            return (1 << zeros) - 1 + (try read(zeros))
        }
    }
}
