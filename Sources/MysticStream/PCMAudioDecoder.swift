import Foundation
import MysticKit
import MysticCore

/// One packet in, routed float PCM out. The player holds whichever the stream's codec needs, so a
/// Rubylight host's uncompressed audio goes through the same playout, routing and ring as Opus.
protocol StreamAudioDecoder: AnyObject {
    var info: AudioSetupInfo { get }
    /// `packet` nil is a lost one. Calls `consume` before returning; its pointer must not escape.
    func decode(_ packet: UnsafeRawBufferPointer?,routing: AudioChannelRouting?,consume: (UnsafeBufferPointer<Float>, Int) -> Void) throws
}

extension OpusAudioDecoder: StreamAudioDecoder {}

func makeStreamAudioDecoder(_ info: AudioSetupInfo) throws -> any StreamAudioDecoder {
    switch info.codec {
    case .opus: return try OpusAudioDecoder(info)
    case .pcm: return try PCMAudioDecoder(info)
    default: throw AudioPlaybackError("The PC sent audio in \(info.codec), which Mystic cannot play.")
    }
}

/// Rubylight's uncompressed audio (Nightjar's `pcm_s16le`): s16le samples, interleaved in decoded
/// Opus's channel order, so the same routing applies. PCM has no concealment: a lost or late packet
/// plays as a packet of silence, as in Nightjar. No buffering is added; a packet is converted and
/// written straight to the ring, as a decoded Opus one is.
final class PCMAudioDecoder {
    let info: AudioSetupInfo
    private let channels: Int
    private let stereoRouting: AudioChannelRouting
    private var pcm: [Float]
    private var routed: [Float]
    /// Opus's largest packet, 120 ms; Rubylight's PCM packets are 1 to 5 ms.
    static let maxFrames=5760
    init(_ info: AudioSetupInfo) throws {
        let channels=Int(info.channelCount)
        guard info.codec == .pcm,[2,6,8].contains(channels),info.sampleRate == 48000,
              info.packetDurationMs > 0,info.packetDurationMs <= 120,
              info.samplesPerFrame == info.packetDurationMs*48,Int(info.samplesPerFrame) <= Self.maxFrames else {
            throw AudioPlaybackError("Invalid negotiated PCM configuration.")
        }
        stereoRouting=try AudioChannelRouting(channelCount:channels,channelMask:info.channelMask)
        self.info=info;self.channels=channels
        pcm=Array(repeating:0,count:Self.maxFrames*channels)
        routed=Array(repeating:0,count:Self.maxFrames*8)
    }
    func decode(_ packet: UnsafeRawBufferPointer?,routing: AudioChannelRouting? = nil,consume: (UnsafeBufferPointer<Float>, Int) -> Void) throws {
        let routing=routing ?? stereoRouting
        guard routing.inputChannels == channels,routing.channelMask == info.channelMask else { throw AudioPlaybackError("Audio route disagrees with negotiated channels.") }
        let frames: Int
        if let packet {
            // A trailing partial frame is dropped, as Nightjar does.
            frames=min(packet.count/(2*channels),Self.maxFrames)
            guard frames > 0 else { throw AudioPlaybackError("Invalid PCM packet length.") }
            pcm.withUnsafeMutableBufferPointer { out in
                for index in 0..<frames*channels {
                    let sample=Int16(littleEndian:packet.loadUnaligned(fromByteOffset:index*2,as:Int16.self))
                    out[index]=Float(sample)/32768
                }
            }
        } else {
            frames=Int(info.samplesPerFrame)
            pcm.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating:0,count:frames*channels) }
        }
        let mixed=pcm.withUnsafeBufferPointer { input in
            routed.withUnsafeMutableBufferPointer { output in routing.route(input,frames:frames,into:output) }
        }
        guard mixed else { throw AudioPlaybackError("Invalid PCM samples.") }
        routed.withUnsafeBufferPointer { consume(UnsafeBufferPointer(start:$0.baseAddress,count:frames*routing.outputChannels),frames) }
    }
}

extension PCMAudioDecoder: StreamAudioDecoder {}
