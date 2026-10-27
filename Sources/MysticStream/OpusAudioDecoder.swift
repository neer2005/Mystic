import Foundation
import CMystic
import MysticKit
import MysticCore

public struct AudioPlaybackError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Serial-use decoder. Borrows the packet only during `decode`, and owns reusable PCM buffers.
final class OpusAudioDecoder {
    let info: AudioSetupInfo
    private let handle: OpaquePointer
    private let matrix: StereoMixMatrix
    private var pcm: [Float]
    private var stereo: [Float] = Array(repeating: 0, count: 5760*2)
    init(_ info: AudioSetupInfo) throws {
        let channels = Int(info.channelCount)
        guard (1...8).contains(channels), info.sampleRate == 48000, info.streams > 0,
              info.coupledStreams <= info.streams,
              Int(info.streams)+Int(info.coupledStreams) <= channels,
              info.mapping.count == channels,
              info.mapping.allSatisfy({ $0 == 255 || Int($0) < Int(info.streams)+Int(info.coupledStreams) }),
              info.packetDurationMs > 0, info.packetDurationMs <= 120,
              info.samplesPerFrame == info.packetDurationMs*48, info.samplesPerFrame <= 5760 else {
            throw AudioPlaybackError("Invalid negotiated Opus configuration.")
        }
        matrix = try StereoMixMatrix(channelCount: channels, channelMask: info.channelMask)
        var setup = MysticAudioSetup()
        setup.channel_count = info.channelCount; setup.channel_mask = info.channelMask
        setup.packet_duration_ms = info.packetDurationMs; setup.samples_per_frame = info.samplesPerFrame
        setup.sample_rate = info.sampleRate; setup.streams = info.streams; setup.coupled_streams = info.coupledStreams
        withUnsafeMutableBytes(of: &setup.mapping) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 255)
            bytes.copyBytes(from: info.mapping)
        }
        guard let handle = mystic_opus_new(&setup) else { throw AudioPlaybackError("libopus refused the negotiated channel mapping.") }
        self.handle = handle; self.info = info
        pcm = Array(repeating: 0, count: 5760*channels)
    }
    deinit { mystic_opus_free(handle) }
    /// Calls `consume` before returning; its stereo pointer must not escape.
    func decode(_ packet: UnsafeRawBufferPointer?, consume: (UnsafeBufferPointer<Float>, Int) -> Void) throws {
        if let packet, packet.isEmpty || packet.count > 65536 { throw AudioPlaybackError("Invalid Opus packet length.") }
        let capacity: UInt32 = packet == nil ? info.samplesPerFrame : 5760
        let count = pcm.withUnsafeMutableBufferPointer { buffer in
            mystic_opus_decode(handle, packet?.baseAddress?.assumingMemoryBound(to: UInt8.self), packet?.count ?? 0,
                               buffer.baseAddress, buffer.count, capacity)
        }
        guard count > 0 else { throw AudioPlaybackError("Opus decode failed (code \(count)).") }
        let mixed = pcm.withUnsafeBufferPointer { input in
            stereo.withUnsafeMutableBufferPointer { output in matrix.mix(input, frames: Int(count), into: output) }
        }
        guard mixed else { throw AudioPlaybackError("Invalid decoded PCM samples.") }
        stereo.withUnsafeBufferPointer { consume($0, Int(count)) }
    }
}
