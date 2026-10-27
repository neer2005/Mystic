import XCTest
import Foundation
import AVFoundation
import CMystic
import MysticKit
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
    private func energy(_ pcm:[Float],channel:Int,frequency:Double)->Double {
        var real=0.0,imaginary=0.0
        for i in 960..<pcm.count/2 {
            let phase=2*Double.pi*frequency*Double(i)/48000
            real += Double(pcm[i*2+channel])*cos(phase); imaginary += Double(pcm[i*2+channel])*sin(phase)
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
}
