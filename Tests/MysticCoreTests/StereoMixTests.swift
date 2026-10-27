import Testing
@testable import MysticCore

struct StereoMixTests {
    private func mix(_ samples: [Float], channels: Int, mask: UInt16) throws -> [Float] {
        let matrix = try StereoMixMatrix(channelCount: channels, channelMask: mask)
        var output = [Float](repeating: 0, count: samples.count/channels*2)
        let success = samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { matrix.mix(input, frames: samples.count/channels, into: $0) }
        }
        #expect(success)
        return output
    }
    @Test func stereoAndMono() throws {
        #expect(try mix([0.25,-0.5,0.4,0.6],channels:2,mask:3) == [0.25,-0.5,0.4,0.6])
        #expect(try mix([0.2,0.7],channels:1,mask:4) == [0.2,0.2,0.7,0.7])
    }
    @Test func speakerRoutingAndHeadroom() throws {
        let fl = try mix([1,0,0,0,0,0],channels:6,mask:0x3f)
        let fr = try mix([0,1,0,0,0,0],channels:6,mask:0x3f)
        let center = try mix([0,0,1,0,0,0],channels:6,mask:0x3f)
        let rearLeft = try mix([0,0,0,0,1,0],channels:6,mask:0x3f)
        #expect(fl[0] > 0 && fl[1] == 0)
        #expect(fr[1] == fl[0] && fr[0] == 0)
        #expect(center[0] == center[1] && center[0] > 0)
        #expect(rearLeft[0] > 0 && rearLeft[1] == 0)
        #expect(try mix([0,0,0,1,0,0],channels:6,mask:0x3f) == [0,0])
        let all = try mix(Array(repeating:1,count:8),channels:8,mask:0x63f)
        #expect(all.allSatisfy { $0 <= 1 && $0 > 0.99 })
    }
    @Test func invalidLayoutsAndBuffers() throws {
        #expect(throws: StereoMixMatrix.MixError.self) { _ = try StereoMixMatrix(channelCount:6,channelMask:3) }
        #expect(throws: StereoMixMatrix.MixError.self) { _ = try StereoMixMatrix(channelCount:1,channelMask:0x8000) }
        let matrix = try StereoMixMatrix(channelCount:2,channelMask:3)
        var output=[Float](repeating:0,count:2)
        let tooShort = [Float](repeating:0,count:1).withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { matrix.mix(input,frames:1,into:$0) }
        }
        #expect(!tooShort)
        let nonFinite = [Float.nan,0].withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { matrix.mix(input,frames:1,into:$0) }
        }
        #expect(!nonFinite)
    }
}
