import Foundation
import AVFoundation
import AudioToolbox
import CMystic
import MysticKit

public struct AudioPlaybackStats: Sendable {
    public let decodedPackets: UInt64
    public let concealedPackets: UInt64
    public let decodeErrors: UInt64
    public let renderedFrames: UInt64
    public let queuedFrames: UInt32
    public let droppedFrames: UInt64
    public let underrunFrames: UInt64
}

/// One serialized producer feeds a real-time source node. The render block only calls the
/// SPSC ring reader: no locks, allocation, decoding, dispatch, or logging on the audio thread.
public final class AudioPlayer: AudioConsumer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mystic.Audio")
    private let log: @Sendable (String) -> Void
    private var decoder: OpusAudioDecoder?
    private var pipeline: AudioPipeline?
    private var running = false
    private var volume: Float = 0.8
    private var muted = false
    private var generation: UInt64 = 0
    private var decoded: UInt64 = 0, concealed: UInt64 = 0, errors: UInt64 = 0
    public init(log: @escaping @Sendable (String) -> Void = { _ in }) { self.log = log }
    deinit { pipeline?.stop() }
    public func setup(_ info: AudioSetupInfo) throws {
        try queue.sync {
            stopLocked(); decoder = nil
            decoded = 0; concealed = 0; errors = 0
            let next = try OpusAudioDecoder(info)
            let output = try makePipeline()
            decoder = next; pipeline = output
            log("Audio setup: Opus \(info.channelCount) channels at \(info.sampleRate) Hz, \(info.samplesPerFrame) samples/packet → stereo")
        }
    }
    public func start() {
        queue.sync {
            if decoder != nil && pipeline == nil {
                do { pipeline = try makePipeline() } catch { log("Audio start failed: \(error.localizedDescription)") }
            }
            running = decoder != nil && pipeline != nil
        }
    }
    public func play(_ packet: UnsafeRawBufferPointer?) {
        queue.sync {
            guard running, let decoder, let pipeline else { return }
            do {
                try decode(decoder, packet: packet, ring: pipeline.render.ring)
                if packet == nil { concealed += 1 } else { decoded += 1 }
            } catch {
                errors += 1
                if errors <= 3 || errors % 100 == 0 { log(error.localizedDescription) }
                // Malformed packets are treated as lost, so the audio clock keeps moving.
                if packet != nil {
                    do { try decode(decoder, packet: nil, ring: pipeline.render.ring); concealed += 1 }
                    catch { if errors <= 3 { log("Opus concealment failed: \(error.localizedDescription)") } }
                }
            }
        }
    }
    private func decode(_ decoder: OpusAudioDecoder, packet: UnsafeRawBufferPointer?, ring: OpaquePointer) throws {
        try decoder.decode(packet) { samples, frames in
            _ = mystic_pcm_ring_write(ring, samples.baseAddress, UInt32(frames))
        }
    }
    public func stop() { queue.sync { stopLocked() } }
    public func cleanup() { queue.sync { stopLocked(); decoder = nil } }
    public func setVolume(_ volume: Float, muted: Bool) {
        queue.sync {
            self.volume = volume.isFinite ? min(1,max(0,volume)) : 0
            self.muted = muted
            if let pipeline { mystic_pcm_ring_set_gain(pipeline.render.ring, muted ? 0 : self.volume) }
        }
    }
    public var statistics: AudioPlaybackStats {
        queue.sync {
            let s = pipeline.map { mystic_pcm_ring_stats($0.render.ring) } ?? MysticPCMStats()
            return AudioPlaybackStats(decodedPackets: decoded, concealedPackets: concealed, decodeErrors: errors,
                renderedFrames: s.rendered_frames, queuedFrames: s.queued_frames, droppedFrames: s.dropped_frames,
                underrunFrames: s.underrun_frames)
        }
    }
    private func makePipeline() throws -> AudioPipeline {
        let output = try AudioPipeline(volume: muted ? 0 : volume)
        output.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: output.engine, queue: nil) { [weak self, weak output] _ in
                guard let self, let output else { return }
                self.queue.async { [weak self, weak output] in
                    guard let self, let output, self.pipeline === output else { return }
                    self.rebuildOutput()
                }
            }
        return output
    }
    private func rebuildOutput() {
        // New ring/source generations discard old buffered audio on route/sample-rate changes.
        pipeline?.stop(); pipeline = nil
        do { pipeline = try makePipeline(); log("Audio output restarted after a device change.") }
        catch {
            log("Audio output unavailable: \(error.localizedDescription)")
            let resume = running; running = false
            retryOutput(generation: generation, attempts: 3, resume: resume)
        }
    }
    private func retryOutput(generation token: UInt64, attempts: Int, resume: Bool) {
        guard attempts > 0 else { return }
        queue.asyncAfter(deadline: .now()+1) { [weak self] in
            guard let self, self.generation == token, self.decoder != nil, self.pipeline == nil else { return }
            do {
                self.pipeline = try self.makePipeline()
                self.running = resume
                self.log("Audio output recovered after device reconfiguration.")
            } catch {
                self.retryOutput(generation: token, attempts: attempts-1, resume: resume)
            }
        }
    }
    private func stopLocked() { generation &+= 1; running = false; pipeline?.stop(); pipeline = nil }
}

final class AudioRenderState: @unchecked Sendable {
    let ring: OpaquePointer
    init() throws {
        guard let ring = mystic_pcm_ring_new(8192,2880) else { throw AudioPlaybackError("Unable to allocate audio ring.") }
        self.ring = ring
    }
    deinit { mystic_pcm_ring_free(ring) }
}
final class AudioPipeline: @unchecked Sendable {
    let engine = AVAudioEngine()
    let render: AudioRenderState
    let source: AVAudioSourceNode
    var observer: NSObjectProtocol?
    init(volume: Float, manualRendering: Bool = false) throws {
        let render = try AudioRenderState()
        self.render = render
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw AudioPlaybackError("Unable to create stereo PCM format.")
        }
        source = AVAudioSourceNode(format: format) { [render] silence, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData,
                  buffers[0].mDataByteSize/4 >= count, buffers[1].mDataByteSize/4 >= count else {
                for buffer in buffers { if let data = buffer.mData { memset(data,0,Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return kAudio_ParamError
            }
            let read = mystic_pcm_ring_read(render.ring, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self), count)
            silence.pointee = ObjCBool(read == 0)
            return noErr
        }
        if manualRendering { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
        engine.attach(source)
        try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        mystic_pcm_ring_set_gain(render.ring,volume)
        engine.prepare()
        try engine.start()
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        engine.stop()
    }
    deinit { stop() }
}
