import XCTest
import Foundation
import AVFoundation
import CMystic
import MysticKit
import MysticCore
@testable import MysticStream

final class AudioTests: XCTestCase {
    private struct Fixture: Decodable {
        let sampleRate: UInt32, channelCount: UInt8, channelMask: UInt16
        let streams: UInt8, coupledStreams: UInt8, mapping: [UInt8]
        let samplesPerFrame: UInt32, packetDurationMs: UInt32
        let frequencies: [Double], packets: [Data]
        var info: AudioSetupInfo {
            AudioSetupInfo(channelCount:channelCount,channelMask:channelMask,packetDurationMs:packetDurationMs,
                samplesPerFrame:samplesPerFrame,sampleRate:sampleRate,streams:streams,coupledStreams:coupledStreams,mapping:mapping)
        }
    }
    private func fixture(_ name: String) throws -> Fixture {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"audio-"+name,withExtension:"json",subdirectory:"Fixtures"))
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
    }
    func testStereoDecodeAndConcealment() throws {
        let f=try fixture("stereo"), decoder=try OpusAudioDecoder(f.info)
        var pcm:[Float]=[]
        for packet in f.packets {
            try packet.withUnsafeBytes { bytes in
                try decoder.decode(bytes) { samples,frames in
                    XCTAssertEqual(frames,240); pcm.append(contentsOf:samples.prefix(frames*2))
                }
            }
        }
        XCTAssertGreaterThan(energy(pcm,channel:0,frequency:250),energy(pcm,channel:0,frequency:350)*5)
        XCTAssertGreaterThan(energy(pcm,channel:1,frequency:350),energy(pcm,channel:1,frequency:250)*5)
        try decoder.decode(nil) { samples,frames in
            XCTAssertEqual(frames,240); XCTAssertTrue(samples.prefix(frames*2).allSatisfy(\.isFinite))
        }
        XCTAssertThrowsError(try Data().withUnsafeBytes { try decoder.decode($0) { _,_ in } })
        XCTAssertThrowsError(try Data([255,255,255]).withUnsafeBytes { try decoder.decode($0) { _,_ in } })
    }
    func testSurroundDecodeDownmix() throws {
        let f=try fixture("surround51"), decoder=try OpusAudioDecoder(f.info)
        var pcm:[Float]=[]
        for packet in f.packets {
            try packet.withUnsafeBytes { bytes in try decoder.decode(bytes) { s,n in pcm.append(contentsOf:s.prefix(n*2)) } }
        }
        // Source fixture channels are FL=250, FR=350, FC=450, LFE=550, BL=650, BR=750 Hz.
        for (channel,keep,reject) in [(0,250.0,350.0),(1,350.0,250.0),(0,650.0,750.0),(1,750.0,650.0)] {
            XCTAssertGreaterThan(energy(pcm,channel:channel,frequency:keep),energy(pcm,channel:channel,frequency:reject)*3)
        }
        for channel in 0..<2 {
            XCTAssertGreaterThan(energy(pcm,channel:channel,frequency:450),energy(pcm,channel:channel,frequency:550)*3)
        }
    }
    private func energy(_ pcm:[Float],channel:Int,frequency:Double,channels:Int = 2)->Double {
        var real=0.0,imaginary=0.0
        for i in 960..<pcm.count/channels {
            let phase=2*Double.pi*frequency*Double(i)/48000
            real += Double(pcm[i*channels+channel])*cos(phase); imaginary += Double(pcm[i*channels+channel])*sin(phase)
        }
        return real*real+imaginary*imaginary
    }
    func testManualEngineRendersAndMutes() throws {
        let graph=try AudioPipeline(volume:1,manualRendering:true)
        defer { graph.stop() }
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:graph.engine.manualRenderingFormat,frameCapacity:1024))
        let data=(0..<2048).map { Float($0%2==0 ? 0.25 : -0.5) }
        XCTAssertEqual(data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) },1024)
        XCTAssertEqual(try graph.engine.renderOffline(1024,to:buffer),.success)
        let channels=try XCTUnwrap(buffer.floatChannelData)
        XCTAssertGreaterThan((0..<1024).map { abs(channels[0][$0]) }.max() ?? 0,0.1)
        XCTAssertLessThan(channels[1][1023],-0.1)
        mystic_pcm_ring_set_gain(graph.render.ring,0)
        _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) }
        XCTAssertEqual(try graph.engine.renderOffline(1024,to:buffer),.success)
        // The render-side gain ramps over 128 frames; subsequent output must be silent.
        _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) }
        XCTAssertEqual(try graph.engine.renderOffline(1024,to:buffer),.success)
        XCTAssertTrue((0..<1024).allSatisfy { abs(channels[0][$0]) < 0.0001 && abs(channels[1][$0]) < 0.0001 })
    }
    func testInvalidNegotiationAndRepeatedCleanup() throws {
        var info=try fixture("stereo").info
        info.mapping=[0]
        XCTAssertThrowsError(try OpusAudioDecoder(info))
        info=try fixture("stereo").info; info.sampleRate=44100
        XCTAssertThrowsError(try OpusAudioDecoder(info))
        info=try fixture("stereo").info; info.streams=0
        XCTAssertThrowsError(try OpusAudioDecoder(info))
        let player=AudioPlayer()
        player.start(); player.play(nil); player.stop(); player.cleanup(); player.cleanup()
        XCTAssertEqual(player.statistics.decodedPackets,0)
        player.setVolume(.nan,muted:false)
    }
    func testNewMutedEngineIsSilentFromItsFirstSample() throws {
        let graph=try AudioPipeline(volume:0,manualRendering:true)
        defer { graph.stop() }
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:graph.engine.manualRenderingFormat,frameCapacity:512))
        let data=Array(repeating:Float(0.5),count:1024)
        _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,512) }
        XCTAssertEqual(try graph.engine.renderOffline(512,to:buffer),.success)
        let channels=try XCTUnwrap(buffer.floatChannelData)
        XCTAssertTrue((0..<512).allSatisfy { channels[0][$0] == 0 && channels[1][$0] == 0 })
    }
    func testNativeMixerConvertsStreamRateToCommonOutputRates() throws {
        for rate in [16_000.0,44_100.0,96_000.0] {
            let graph=try AudioPipeline(volume:1,manualRendering:true,manualSampleRate:rate)
            defer { graph.stop() }
            XCTAssertEqual(graph.sampleRate,rate)
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:graph.engine.manualRenderingFormat,frameCapacity:256))
            let data=Array(repeating:Float(0.25),count:2048)
            _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) }
            XCTAssertEqual(try graph.engine.renderOffline(256,to:buffer),.success)
            let channels=try XCTUnwrap(buffer.floatChannelData)
            XCTAssertTrue((0..<256).allSatisfy { channels[0][$0].isFinite && channels[1][$0].isFinite })
            XCTAssertGreaterThan((0..<256).map { abs(channels[0][$0]) }.max() ?? 0,0.1)
        }
    }
    func testNativeOutputMonitorCanBeRestartedAndStoppedWithoutChangingDevices() throws {
        let monitor=AudioOutputMonitor()
        defer { monitor.stop() }
        try monitor.start(changed:{})
        try monitor.refresh();monitor.stop();monitor.stop()
        try monitor.start(changed:{});try monitor.refresh()
    }
    func testDiscreteOpusTonesKeepEverySpeakerIncludingLFEAndDistinctSideRearPairs() throws {
        let speakers: [AudioSpeaker]=[.left,.right,.center,.lfe,.surroundLeft,.surroundRight,.rearLeft,.rearRight]
        for name in ["surround51","surround71"] {
            let fixture=try fixture(name),channels=Int(fixture.channelCount)
            let route=try AudioChannelRouting(channelCount:channels,channelMask:fixture.channelMask,destination:Array(speakers.prefix(channels)))
            XCTAssertTrue(route.isDiscrete)
            let decoder=try OpusAudioDecoder(fixture.info)
            var pcm: [Float] = []
            for packet in fixture.packets {
                try packet.withUnsafeBytes { try decoder.decode($0,routing:route) { samples,frames in
                    XCTAssertEqual(samples.count,frames*channels);pcm.append(contentsOf:samples)
                } }
            }
            let sourceIndices=channels == 8 ? [0,1,2,3,6,7,4,5] : [0,1,2,3,4,5]
            for channel in 0..<channels {
                let expected=fixture.frequencies[sourceIndices[channel]]
                let signal=energy(pcm,channel:channel,frequency:expected,channels:channels)
                for frequency in fixture.frequencies where frequency != expected {
                    XCTAssertGreaterThan(signal,energy(pcm,channel:channel,frequency:frequency,channels:channels)*3,"\(name) channel \(channel)")
                }
            }
            try decoder.decode(nil,routing:route) { samples,frames in
                XCTAssertEqual(samples.count,frames*channels);XCTAssertTrue(samples.allSatisfy(\.isFinite))
            }
        }
    }
    func testNativeSurroundRendererPreservesConfiguredSpeakerOrderAcrossRatesAndMute() throws {
        let configurations: [[AudioSpeaker]]=[
            [.left,.right,.center,.lfe,.surroundLeft,.surroundRight],
            [.lfe,.right,.rearRight,.surroundLeft,.center,.rearLeft,.left,.surroundRight]
        ]
        for speakers in configurations {
            for rate in [48_000.0,44_100.0,96_000.0] {
                let channels=speakers.count
                let info=AudioSetupInfo(channelCount:UInt8(channels),channelMask:channels == 6 ? 0x3F : 0x63F,packetDurationMs:5,samplesPerFrame:240,
                    streams:UInt8(channels),coupledStreams:0,mapping:Array(0..<UInt8(channels)))
                let graph=try AudioPipeline(volume:1,info:info,manualRendering:true,manualSampleRate:rate,manualSpeakers:speakers)
                defer { graph.stop() }
                XCTAssertTrue(graph.routing.isDiscrete);XCTAssertEqual(graph.render.channels,channels)
                let format=graph.engine.manualRenderingFormat
                XCTAssertEqual(format.channelCount,UInt32(channels))
                let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:512))
                let source=(0..<channels).map { Float($0+1)*0.05 }
                let data=(0..<1024).flatMap { _ in source }
                XCTAssertEqual(data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) },1024)
                XCTAssertEqual(try graph.engine.renderOffline(512,to:buffer),.success)
                let output=try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<channels {
                    XCTAssertEqual(output[channel][511],source[channel],accuracy:0.002,"\(channels)ch at \(rate) Hz")
                }
                mystic_pcm_ring_set_gain(graph.render.ring,0)
                _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) }
                _=try graph.engine.renderOffline(512,to:buffer)
                _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) }
                XCTAssertEqual(try graph.engine.renderOffline(512,to:buffer),.success)
                for channel in 0..<channels { XCTAssertEqual(output[channel][511],0,accuracy:0.00001) }
            }
        }
    }
    func testNamedAndBitmapSpeakerLayoutsNeverConfuseSideAndRearSpeakers() throws {
        let five=try XCTUnwrap(AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MPEG_5_1_A))
        XCTAssertEqual(AudioSpeakerLayout(five)?.speakers,[.left,.right,.center,.lfe,.surroundLeft,.surroundRight])
        let seven=try XCTUnwrap(AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_MPEG_7_1_C))
        XCTAssertEqual(AudioSpeakerLayout(seven)?.speakers,[.left,.right,.center,.lfe,.surroundLeft,.surroundRight,.rearLeft,.rearRight])
        var bitmap=AudioChannelLayout()
        bitmap.mChannelLayoutTag=kAudioChannelLayoutTag_UseChannelBitmap
        bitmap.mChannelBitmap=AudioChannelBitmap(rawValue:0x63F)
        let windows=withUnsafePointer(to:&bitmap) { AVAudioChannelLayout(layout:$0) }
        XCTAssertEqual(AudioSpeakerLayout(windows)?.speakers,[.left,.right,.center,.lfe,.rearLeft,.rearRight,.surroundLeft,.surroundRight])
        let unknown=try XCTUnwrap(AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | 8))
        XCTAssertNil(AudioSpeakerLayout(unknown))
        let duplicates: [AudioSpeaker]=[.left,.right,.center,.lfe,.surroundLeft,.surroundLeft]
        XCTAssertNil(AudioSpeakerLayout.configured(duplicates))
    }
    func testInsufficientDestinationFallsBackToStereoWithoutChangingNegotiation() throws {
        let fixture=try fixture("surround71")
        let graph=try AudioPipeline(volume:1,info:fixture.info,manualRendering:true,
            manualSpeakers:[.left,.right,.center,.lfe,.surroundLeft,.surroundRight])
        defer { graph.stop() }
        XCTAssertFalse(graph.routing.isDiscrete);XCTAssertEqual(graph.render.channels,2)
        XCTAssertEqual(graph.routing.inputChannels,8);XCTAssertNotNil(graph.routing.fallbackReason)
        let decoder=try OpusAudioDecoder(fixture.info)
        try fixture.packets[0].withUnsafeBytes { try decoder.decode($0,routing:graph.routing) { samples,frames in
            XCTAssertEqual(samples.count,frames*2)
            _=mystic_pcm_ring_write(graph.render.ring,samples.baseAddress,UInt32(frames))
        } }
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:graph.engine.manualRenderingFormat,frameCapacity:240))
        XCTAssertEqual(try graph.engine.renderOffline(240,to:buffer),.success)
    }
    private func pcmInfo(channels: UInt8,mask: UInt16,ms: UInt32) -> AudioSetupInfo {
        AudioSetupInfo(channelCount:channels,channelMask:mask,packetDurationMs:ms,samplesPerFrame:48*ms,codec:.pcm)
    }
    func testPCMDecodesLittleEndianSamplesAndPlaysALostPacketAsSilence() throws {
        let info=pcmInfo(channels:2,mask:3,ms:5)
        let decoder=try XCTUnwrap(makeStreamAudioDecoder(info) as? PCMAudioDecoder)
        var bytes=[UInt8]()
        for _ in 0..<240 {
            for value in [Int16(16384),Int16(-32768)] { withUnsafeBytes(of:value.littleEndian) { bytes.append(contentsOf:$0) } }
        }
        var decoded=0
        try bytes.withUnsafeBytes { packet in
            try decoder.decode(packet) { samples,frames in
                decoded=frames;XCTAssertEqual(samples.count,480)
                XCTAssertEqual(samples[0],0.5);XCTAssertEqual(samples[1],-1)
                XCTAssertEqual(samples[478],0.5);XCTAssertEqual(samples[479],-1)
            }
        }
        XCTAssertEqual(decoded,240)
        try decoder.decode(nil) { samples,frames in
            XCTAssertEqual(frames,240);XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        }
        // A trailing partial frame is dropped, as Nightjar does; an empty packet is refused.
        try bytes.prefix(10).map { $0 }.withUnsafeBytes { packet in
            try decoder.decode(packet) { _,frames in XCTAssertEqual(frames,2) }
        }
        XCTAssertThrowsError(try [UInt8(1),2].withUnsafeBytes { try decoder.decode($0) { _,_ in } })
    }
    func testPCMSurroundUsesTheSameRoutingAsOpus() throws {
        // Rubylight's 7.1 PCM comes in 1 ms packets, in the channel-mask order decoded Opus has.
        let info=pcmInfo(channels:8,mask:0x63F,ms:1)
        let decoder=try PCMAudioDecoder(info)
        let samples=(0..<48*8).map { Int16(($0%8)*1000) }
        let stereo=try AudioChannelRouting(channelCount:8,channelMask:0x63F)
        try samples.withUnsafeBytes { packet in
            try decoder.decode(packet) { routed,frames in
                XCTAssertEqual(frames,48);XCTAssertEqual(routed.count,96)
            }
            let float=samples.map { Float($0)/32768 }
            var expected=[Float](repeating:0,count:96)
            _=float.withUnsafeBufferPointer { input in expected.withUnsafeMutableBufferPointer { stereo.route(input,frames:48,into:$0) } }
            try decoder.decode(packet,routing:stereo) { routed,_ in XCTAssertEqual(Array(routed),expected) }
        }
    }
    func testOnlyOpusAndPCMAreAccepted() throws {
        XCTAssertTrue(try makeStreamAudioDecoder(try fixture("stereo").info) is OpusAudioDecoder)
        XCTAssertThrowsError(try makeStreamAudioDecoder(AudioSetupInfo(channelCount:2,channelMask:3,packetDurationMs:32,
            samplesPerFrame:1536,codec:StreamAudioCodec(rawValue:4))))
        XCTAssertThrowsError(try PCMAudioDecoder(pcmInfo(channels:1,mask:4,ms:5)))
        var info=pcmInfo(channels:2,mask:3,ms:5);info.sampleRate=44100
        XCTAssertThrowsError(try PCMAudioDecoder(info))
        info=pcmInfo(channels:2,mask:3,ms:5);info.samplesPerFrame=200
        XCTAssertThrowsError(try PCMAudioDecoder(info))
    }
    func testPlayerPlaysPCMThroughTheSamePlayout() throws {
        let player=AudioPlayer()
        try player.setup(pcmInfo(channels:2,mask:3,ms:5))
        XCTAssertEqual(player.statistics.codec,.pcm)
        player.cleanup()
    }
    func testStereoOnSurroundOutputDoesNotInventCenterLFEOrSurroundChannels() throws {
        let speakers: [AudioSpeaker]=[.left,.right,.center,.lfe,.surroundLeft,.surroundRight,.rearLeft,.rearRight]
        let graph=try AudioPipeline(volume:1,manualRendering:true,manualSpeakers:speakers)
        defer { graph.stop() }
        XCTAssertEqual(graph.routing.label,"Stereo")
        let data=(0..<1024).flatMap { _ in [Float(0.25),Float(-0.5)] }
        _=data.withUnsafeBufferPointer { mystic_pcm_ring_write(graph.render.ring,$0.baseAddress,1024) }
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:graph.engine.manualRenderingFormat,frameCapacity:512))
        XCTAssertEqual(try graph.engine.renderOffline(512,to:buffer),.success)
        let output=try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(output[0][511],0.25,accuracy:0.00001)
        XCTAssertEqual(output[1][511],-0.5,accuracy:0.00001)
        for channel in 2..<8 { XCTAssertTrue((0..<512).allSatisfy { output[channel][$0] == 0 }) }
    }
}
