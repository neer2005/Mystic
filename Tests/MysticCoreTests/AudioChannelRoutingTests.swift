import Testing
import MysticCore

struct AudioChannelRoutingTests {
    private let speakers: [AudioSpeaker]=[.left,.right,.center,.lfe,.surroundLeft,.surroundRight,.rearLeft,.rearRight]
    @Test func sevenOnePreservesSideRearAndLFEInPhysicalSpeakerOrder() throws {
        let route=try AudioChannelRouting(channelCount:8,channelMask:0x63F,destination:speakers)
        #expect(route.isDiscrete)
        let output=process(route,[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8])
        #expect(output == [0.1,0.2,0.3,0.4,0.7,0.8,0.5,0.6])
        #expect(route.label == "7.1 discrete")
    }
    @Test func arbitraryDeviceOrderIsMappedExplicitly() throws {
        let destination: [AudioSpeaker]=[.lfe,.center,.right,.left,.surroundRight,.surroundLeft]
        let route=try AudioChannelRouting(channelCount:6,channelMask:0x3F,destination:destination)
        #expect(process(route,[0.1,0.2,0.3,0.4,0.5,0.6]) == [0.4,0.3,0.2,0.1,0.6,0.5])
    }
    @Test func fiveOneOnSevenOneLeavesUnusedRearSpeakersSilent() throws {
        for mask: UInt16 in [0x3F,0x60F] {
            let route=try AudioChannelRouting(channelCount:6,channelMask:mask,destination:speakers)
            #expect(route.isDiscrete)
            #expect(process(route,[0.1,0.2,0.3,0.4,0.5,0.6]) == [0.1,0.2,0.3,0.4,0.5,0.6,0,0])
        }
        let rearOnly: [AudioSpeaker]=[.left,.right,.center,.lfe,.rearLeft,.rearRight]
        let route=try AudioChannelRouting(channelCount:6,channelMask:0x3F,destination:rearOnly)
        #expect(route.isDiscrete)
        #expect(process(route,[0.1,0.2,0.3,0.4,0.5,0.6]) == [0.1,0.2,0.3,0.4,0.5,0.6])
    }
    @Test func unsupportedUnknownAndInsufficientLayoutsUseExistingStereoDownmix() throws {
        for destination: [AudioSpeaker]? in [nil,[.left,.right],Array(speakers.prefix(6)),Array(repeating:.left,count:8)] {
            let route=try AudioChannelRouting(channelCount:8,channelMask:0x63F,destination:destination)
            #expect(!route.isDiscrete);#expect(route.outputChannels == 2);#expect(route.fallbackReason != nil)
            let actual=process(route,[1,0,0,0,0,0,0,0])
            #expect(actual[0] > 0);#expect(actual[1] == 0)
        }
        let stereo=try AudioChannelRouting(channelCount:2,channelMask:3,destination:speakers)
        #expect(!stereo.isDiscrete);#expect(stereo.fallbackReason == nil)
        #expect(process(stereo,[0.25,-0.5]) == [0.25,-0.5])
        let uncommon=try AudioChannelRouting(channelCount:6,channelMask:0x12F,
            destination:[.left,.right,.center,.lfe,.rearLeft,.rearRight])
        #expect(!uncommon.isDiscrete,"An unusual six-channel source must not be relabeled as 5.1")
    }
    @Test func invalidMasksNonFiniteSamplesAndShortBuffersAreRejected() throws {
        #expect(throws:(any Error).self) { try AudioChannelRouting(channelCount:8,channelMask:3,destination:speakers) }
        let route=try AudioChannelRouting(channelCount:8,channelMask:0x63F,destination:speakers)
        var output=Array(repeating:Float(0),count:8)
        let invalid=[Float.nan]+Array(repeating:Float(0),count:7)
        #expect(!invalid.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { route.route(input,frames:1,into:$0) } })
        #expect(![Float(0)].withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { route.route(input,frames:1,into:$0) } })
    }
    private func process(_ route: AudioChannelRouting,_ input: [Float]) -> [Float] {
        var output=Array(repeating:Float(0),count:route.outputChannels)
        #expect(input.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { route.route(input,frames:1,into:$0) } })
        return output
    }
}
