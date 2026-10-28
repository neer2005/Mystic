import XCTest
import Foundation
import CMystic
import MysticKit
@testable import MysticStream

final class MicrophoneTests: XCTestCase {
    func testNativeRatesProduceRealMonoOpusPackets() throws {
        for rate in [44100.0,48000.0,96000.0] {
            let ingress=try MicIngress(maxQueued:UInt32(rate/10)),encoder=try MicrophoneEncoder(sampleRate:rate)
            let decoder=try OpusAudioDecoder(AudioSetupInfo(channelCount:1,channelMask:4,packetDurationMs:20,samplesPerFrame:960,
                                                          streams:1,coupledStreams:0,mapping:[0]))
            var packets=0,energy:Float=0
            let count=Int(rate/50)
            for block in 0..<15 {
                let tone=(0..<count).map { Float(sin(Double(block*count+$0)*440*2*Double.pi/rate)*0.2) }
                tone.withUnsafeBufferPointer { mystic_mic_write(ingress.handle,$0.baseAddress,UInt32(count),1) }
                _=try encoder.drain(ingress.handle) { packet in
                    try decoder.decode(packet) { pcm,frames in
                        XCTAssertEqual(frames,960)
                        energy += pcm.reduce(0) { $0 + abs($1) }
                    };packets+=1
                }
            }
            XCTAssertGreaterThan(packets,10,"Rate \(rate)");XCTAssertGreaterThan(energy,1)
            mystic_mic_mute(ingress.handle,true);encoder.reset()
            XCTAssertEqual(try encoder.drain(ingress.handle) { _ in XCTFail("Muted packet") },0)
            mystic_mic_mute(ingress.handle,false)
            XCTAssertEqual(try encoder.drain(ingress.handle) { _ in XCTFail("Stale packet on resume") },0)
        }
    }
    func testRepeatedStopDoesNotOpenMicrophone() {
        let capture=MicrophoneCapture(queue:DispatchQueue(label:"Mic.Test"),send:{ _ in XCTFail("Unexpected send") },report:{ _ in })
        capture.stop();capture.stop()
    }
}
