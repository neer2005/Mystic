import Foundation
import Testing
@testable import MysticCore

@Suite("Annex B")
struct AnnexBTests {

    /// Builds an Annex B stream from NAL payloads.
    private func annexB(_ nals: [[UInt8]], fourByte: Bool = false) -> Data {
        var data = Data()
        for nal in nals {
            data.append(contentsOf: fourByte ? [0, 0, 0, 1] : [0, 0, 1])
            data.append(contentsOf: nal)
        }
        return data
    }

    @Test("splits three-byte start codes")
    func threeByteStartCodes() {
        let data = annexB([[0x67, 0xAA], [0x68, 0xBB], [0x65, 0xCC]])
        let ranges = AnnexB.nalUnitRanges(in: data)

        #expect(ranges.count == 3)
        #expect(Array(data[ranges[0]]) == [0x67, 0xAA])
        #expect(Array(data[ranges[1]]) == [0x68, 0xBB])
        #expect(Array(data[ranges[2]]) == [0x65, 0xCC])
    }

    @Test("splits four-byte start codes without leaking the extra zero")
    func fourByteStartCodes() {
        let data = annexB([[0x67, 0xAA], [0x68, 0xBB]], fourByte: true)
        let ranges = AnnexB.nalUnitRanges(in: data)

        #expect(ranges.count == 2)
        // The trailing zero of the second prefix must not be part of the first NAL.
        #expect(Array(data[ranges[0]]) == [0x67, 0xAA], "first NAL picked up a start-code zero")
        #expect(Array(data[ranges[1]]) == [0x68, 0xBB])
    }

    @Test("handles a mixed stream, which is what real encoders emit")
    func mixedStartCodes() {
        var data = Data([0, 0, 0, 1])
        data.append(contentsOf: [0x67, 0x01])   // SPS with a 4-byte prefix
        data.append(contentsOf: [0, 0, 1])
        data.append(contentsOf: [0x68, 0x02])   // PPS with a 3-byte prefix
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(contentsOf: [0x65, 0x03])   // IDR

        let ranges = AnnexB.nalUnitRanges(in: data)
        #expect(ranges.count == 3)
        #expect(Array(data[ranges[1]]) == [0x68, 0x02])
        #expect(Array(data[ranges[2]]) == [0x65, 0x03])
    }

    @Test("trailing zeros are not reported as payload")
    func trailingZeros() {
        var data = annexB([[0x65, 0xAA]])
        data.append(contentsOf: [0, 0])
        let ranges = AnnexB.nalUnitRanges(in: data)

        #expect(ranges.count == 1)
        #expect(Array(data[ranges[0]]) == [0x65, 0xAA])
    }

    @Test("degenerate input yields no units instead of crashing")
    func degenerateInput() {
        #expect(AnnexB.nalUnitRanges(in: Data()).isEmpty)
        #expect(AnnexB.nalUnitRanges(in: Data([0, 0])).isEmpty)
        #expect(AnnexB.nalUnitRanges(in: Data([0, 0, 1])).isEmpty, "a bare start code has no payload")
        #expect(AnnexB.nalUnitRanges(in: Data([1, 2, 3, 4])).isEmpty, "no start code, no units")
    }

    @Test("AVCC conversion replaces every start code with a length")
    func avccConversion() {
        let data = annexB([[0x67, 0xAA, 0xBB], [0x65, 0xCC]])
        let avcc = AnnexB.avccSample(from: data)

        // 4-byte length (3) + payload, then 4-byte length (2) + payload.
        let expected: [UInt8] = [0, 0, 0, 3, 0x67, 0xAA, 0xBB, 0, 0, 0, 2, 0x65, 0xCC]
        #expect(Array(avcc) == expected)
        #expect(avcc.count == 4 + 3 + 4 + 2)
    }

    @Test("AVCC conversion of an empty frame is empty, not malformed")
    func avccEmpty() {
        #expect(AnnexB.avccSample(from: Data()).isEmpty)
    }

    @Test("emulation prevention bytes are removed")
    func emulationPrevention() {
        // 00 00 03 01 must become 00 00 01.
        let nal = Data([0x67, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00])
        let cleaned = AnnexB.stripEmulationPrevention(nal)

        #expect(Array(cleaned) == [0x67, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
    }

    @Test("a lone 0x03 after fewer than two zeros is kept")
    func loneEmulationByte() {
        let nal = Data([0x67, 0x00, 0x03, 0x03])
        #expect(Array(AnnexB.stripEmulationPrevention(nal)) == [0x67, 0x00, 0x03, 0x03])
    }

    @Test("extracts H.264 SPS and PPS from a keyframe")
    func h264ParameterSets() {
        let data = annexB([
            [0x67, 0x42, 0x00, 0x1E], // SPS (type 7)
            [0x68, 0xCE, 0x38, 0x80], // PPS (type 8)
            [0x65, 0x88, 0x84],       // IDR slice (type 5)
        ])

        let sets = ParameterSets.extract(from: data, codec: .h264)
        #expect(sets != nil)
        #expect(sets?.sps == Data([0x67, 0x42, 0x00, 0x1E]))
        #expect(sets?.pps == Data([0x68, 0xCE, 0x38, 0x80]))
        #expect(sets?.vps == nil, "H.264 has no VPS")
    }

    @Test("extracts HEVC VPS, SPS and PPS")
    func hevcParameterSets() {
        // HEVC type is (byte >> 1) & 0x3F: 0x40>>1 = 32 (VPS), 0x42>>1 = 33 (SPS), 0x44>>1 = 34.
        let data = annexB([
            [0x40, 0x01, 0x0C],
            [0x42, 0x01, 0x01],
            [0x44, 0x01, 0xC0],
            [0x26, 0x01, 0xAF], // IDR_W_RADL
        ])

        let sets = ParameterSets.extract(from: data, codec: .hevc)
        #expect(sets?.vps == Data([0x40, 0x01, 0x0C]))
        #expect(sets?.sps == Data([0x42, 0x01, 0x01]))
        #expect(sets?.pps == Data([0x44, 0x01, 0xC0]))
    }

    @Test("a P-frame without parameter sets returns nil so the caller asks for a key frame")
    func missingParameterSets() {
        let data = annexB([[0x41, 0x9A, 0x00]]) // non-IDR slice
        #expect(ParameterSets.extract(from: data, codec: .h264) == nil)
    }

    @Test("the same bytes are read correctly as H.264 and as HEVC")
    func codecAffectsType() {
        // 0x42: H.264 -> type 2 (slice data); HEVC -> type 33 (SPS).
        let data = annexB([[0x40, 0x01], [0x42, 0x01], [0x44, 0x01]])

        #expect(ParameterSets.extract(from: data, codec: .h264) == nil)
        #expect(ParameterSets.extract(from: data, codec: .hevc) != nil)
    }
}
