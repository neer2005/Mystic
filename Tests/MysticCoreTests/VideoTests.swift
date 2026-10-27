import Foundation
import Testing
@testable import MysticCore

@Suite("Video primitives")
struct VideoTests {
    @Test func parameterBytesRemainEncoded() {
        let sps = Data([0x67, 0, 0, 3, 1, 0x80])
        let input = Data([0,0,1]) + sps + Data([0,0,1,0x68,0x80])
        #expect(ParameterSets.extract(from: input, codec: .h264)?.sps == sps)
        #expect(ParameterSets.extract(from: Data([0,0,1,0x42,1,0x80,0,0,1,0x44,1,0x80]), codec: .hevc) == nil)
    }
    @Test func exactTimestamp() {
        #expect(VideoTimestamp.relativeMicros(9_007_199_254_740_993, origin: 9_007_199_254_740_000) == 993)
        #expect(VideoTimestamp.relativeMicros(0, origin: 0) == 0)
        #expect(VideoTimestamp.relativeMicros(UInt64(Int64.max), origin: 0) == Int64.max)
        #expect(VideoTimestamp.relativeMicros(UInt64.max, origin: 0) == nil)
        #expect(VideoTimestamp.relativeMicros(9, origin: 10) == nil)
    }
    @Test func keyframeRecovery() {
        var state = VideoRecovery()
        let accepted1 = !state.accept(isKeyFrame: false, hasConfiguration: true)
        #expect(accepted1)
        let accepted2 = !state.accept(isKeyFrame: true, hasConfiguration: false)
        #expect(accepted2)
        let accepted3 = state.accept(isKeyFrame: true, hasConfiguration: true)
        #expect(accepted3)
        let accepted4 = state.accept(isKeyFrame: false, hasConfiguration: true)
        #expect(accepted4)
        state.invalidate()
        let accepted5 = !state.accept(isKeyFrame: false, hasConfiguration: true)
        #expect(accepted5)
        let accepted6 = state.accept(isKeyFrame: true, hasConfiguration: true)
        #expect(accepted6)
    }
    @Test func obuValidation() throws {
        #expect(try AV1.units(in: Data([0x12,0])).first?.type == 2)
        #expect(try AV1.configuration(in: Data([0x12,0])) == nil)
        for bytes: [UInt8] in [[0x80], [0x08], [0x0A], [0x0A,127], [0x0A,128,128,128,128,128,128,128,128], [0x0E,7,0], [0x0A,1,255]] {
            #expect(throws: (any Error).self) { _ = try AV1.configuration(in: Data(bytes)) }
        }
        // Payload lengths must not wrap or consume a following OBU header.
        #expect(throws: AV1.ParseError.self) { _ = try AV1.units(in: Data([0x0A,0xFF,0xFF,0xFF,0x7F])) }
    }
    @Test func staticHDRMetadata() throws {
        let cll = Data([3,232,1,144]) // 1000 nit MaxCLL, 400 nit MaxFALL
        let sei = Data([0,0,1,0x4E,1,144,4]) + cll + Data([0x80])
        #expect(try VideoHDRMetadata.extractNAL(from: sei, codec: .hevc).contentLightLevel == cll)
        #expect(throws: AV1.ParseError.self) {
            _ = try VideoHDRMetadata.extractNAL(from: Data([0,0,1,0x4E,1,144,4,1]), codec: .hevc)
        }
        let obu = Data([0x2A,6,1]) + cll + Data([0x80])
        #expect(try VideoHDRMetadata.extractAV1(from: obu).contentLightLevel == cll)
        var mdcv = Data()
        // AV1 RGB primaries: exact binary fractions distinguish reordering and unit conversion.
        for value: UInt16 in [32768,16384,16384,32768,8192,4096,16384,16384] {
            mdcv.append(UInt8(value >> 8)); mdcv.append(UInt8(truncatingIfNeeded: value))
        }
        mdcv.append(contentsOf: [0,3,232,0, 0,0,64,0]) // max=1000, min=1 nit in AV1 units
        let metadata = try VideoHDRMetadata.extractAV1(from: Data([0x2A,26,2]) + mdcv + Data([0x80]))
        #expect(metadata.masteringDisplay?.prefix(4) == Data([0x30,0xD4,0x61,0xA8])) // G: .25, .5 -> 12500,25000
        #expect(metadata.masteringDisplay?.suffix(8) == Data([0,0x98,0x96,0x80, 0,0,0x27,0x10]))
        #expect(VideoHDRMetadata(masteringDisplay: Data([1])).merging(VideoHDRMetadata(contentLightLevel: cll)).masteringDisplay == Data([1]))
    }

}
