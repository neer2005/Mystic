import Foundation
import AVFoundation
import AudioToolbox
import CMystic
import MysticKit

public enum AudioOutputStatus: String, Sendable {
    case idle, playing, recovering, unavailable
    public var label: String {
        switch self {
        case .idle: return "Audio idle"
        case .playing: return "Audio playing"
        case .recovering: return "Audio output recovering"
        case .unavailable: return "Audio output unavailable"
        }
    }
}

public struct AudioPlaybackStats: Sendable {
    public let decodedPackets: UInt64
    public let concealedPackets: UInt64
    public let decodeErrors: UInt64
    public let renderedFrames: UInt64
    public let queuedFrames: UInt32
    public let droppedFrames: UInt64
    public let underrunFrames: UInt64
    public let outputStatus: AudioOutputStatus
    public let outputDevice: String?
    public let outputSampleRate: Double?
    public let outputRestarts: UInt64
    public let discardedOutputFrames: UInt64
}

protocol AudioOutputPipeline: AnyObject, Sendable {
    var render: AudioRenderState { get }
    var device: AudioOutputDevice? { get }
    var sampleRate: Double { get }
    func stop()
}

/// Serialized decode/control feeds a real-time SPSC reader. Device recovery never runs on the render thread.
public final class AudioPlayer: AudioConsumer, @unchecked Sendable {
    private let queue = DispatchQueue(label:"Mystic.Audio")
    private let log: @Sendable (String) -> Void
    private let monitor: any AudioOutputMonitoring
    private let makeOutput: @Sendable (Float,@escaping @Sendable () -> Void) throws -> any AudioOutputPipeline
    private let retryDelay: TimeInterval,routeDelay: TimeInterval
    private var decoder: OpusAudioDecoder?
    private var pipeline: (any AudioOutputPipeline)?
    // Desired playback remains true while output is unavailable, so Opus state keeps advancing.
    private var running=false
    private var volume: Float=0.8,muted=false
    private var generation: UInt64=0,outputRevision: UInt64=0,recoveryRevision: UInt64=0
    private var pending: DispatchWorkItem?
    private var status: AudioOutputStatus = .idle
    private var starts: UInt64=0,discarded: UInt64=0
    private var retired=MysticPCMStats()
    private var decoded: UInt64=0,concealed: UInt64=0,errors: UInt64=0
    public convenience init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(monitor:AudioOutputMonitor(),makeOutput:{ gain,changed in
            try AudioPipeline(volume:gain,configurationChanged:changed)
        },log:log)
    }
    init(monitor: any AudioOutputMonitoring,
         makeOutput: @escaping @Sendable (Float,@escaping @Sendable () -> Void) throws -> any AudioOutputPipeline,
         retryDelay: TimeInterval = 1,routeDelay: TimeInterval = 0.15,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.monitor=monitor;self.makeOutput=makeOutput;self.retryDelay=retryDelay;self.routeDelay=routeDelay;self.log=log
    }
    deinit { pending?.cancel();monitor.stop();pipeline?.stop() }
    public func setup(_ info: AudioSetupInfo) throws {
        try queue.sync {
            stopLocked();decoder=nil
            decoded=0;concealed=0;errors=0;starts=0;discarded=0;retired=MysticPCMStats()
            decoder=try OpusAudioDecoder(info)
            log("Audio setup: Opus \(info.channelCount) channels at \(info.sampleRate) Hz, \(info.samplesPerFrame) samples/packet → stereo")
        }
    }
    public func start() {
        queue.sync {
            guard decoder != nil,!running else { return }
            running=true
            let token=generation
            do {
                try monitor.start { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self,self.running,self.generation == token else { return }
                        do { try self.monitor.refresh() }
                        catch { self.log("Audio device monitoring: \(error.localizedDescription)") }
                        self.beginRecovery(delay:self.routeDelay)
                    }
                }
            } catch { log("Audio device monitoring unavailable: \(error.localizedDescription)") }
            recoveryRevision &+= 1
            attemptOutput(generation:token,recovery:recoveryRevision,retries:3)
        }
    }
    public func play(_ packet: UnsafeRawBufferPointer?) {
        queue.sync {
            guard running,let decoder else { return }
            do {
                try decode(decoder,packet:packet)
                if packet == nil { concealed += 1 } else { decoded += 1 }
            } catch {
                errors += 1
                if errors <= 3 || errors % 100 == 0 { log(error.localizedDescription) }
                if packet != nil {
                    do { try decode(decoder,packet:nil);concealed += 1 }
                    catch { if errors <= 3 { log("Opus concealment failed: \(error.localizedDescription)") } }
                }
            }
        }
    }
    private func decode(_ decoder: OpusAudioDecoder,packet: UnsafeRawBufferPointer?) throws {
        try decoder.decode(packet) { samples,frames in
            if let pipeline { _=mystic_pcm_ring_write(pipeline.render.ring,samples.baseAddress,UInt32(frames)) }
            else { discarded += UInt64(frames) }
        }
    }
    public func stop() { queue.sync { stopLocked() } }
    public func cleanup() { queue.sync { stopLocked();decoder=nil } }
    /// Explicit recovery after the bounded retry budget; never starts a stopped stream.
    public func retryOutput() {
        queue.async { [weak self] in
            guard let self,self.running else { return }
            self.beginRecovery(delay:0)
        }
    }
    public func setVolume(_ volume: Float,muted: Bool) {
        queue.sync {
            self.volume=volume.isFinite ? min(1,max(0,volume)) : 0;self.muted=muted
            if let pipeline { mystic_pcm_ring_set_gain(pipeline.render.ring,muted ? 0 : self.volume) }
        }
    }
    public var statistics: AudioPlaybackStats {
        queue.sync {
            let s=pipeline.map { mystic_pcm_ring_stats($0.render.ring) } ?? MysticPCMStats()
            let sampleRate=pipeline?.sampleRate
            return AudioPlaybackStats(decodedPackets:decoded,concealedPackets:concealed,decodeErrors:errors,
                renderedFrames:retired.rendered_frames+s.rendered_frames,queuedFrames:s.queued_frames,
                droppedFrames:retired.dropped_frames+s.dropped_frames,underrunFrames:retired.underrun_frames+s.underrun_frames,
                outputStatus:status,outputDevice:pipeline?.device?.name,
                outputSampleRate:sampleRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                outputRestarts:starts > 0 ? starts-1 : 0,discardedOutputFrames:discarded)
        }
    }
    private func beginRecovery(delay: TimeInterval) {
        recoveryRevision &+= 1;pending?.cancel();pending=nil
        retireOutput();status = .recovering
        scheduleAttempt(generation:generation,recovery:recoveryRevision,retries:3,delay:delay)
    }
    private func scheduleAttempt(generation token: UInt64,recovery: UInt64,retries: Int,delay: TimeInterval) {
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.running,self.generation == token,self.recoveryRevision == recovery else { return }
            self.pending=nil
            self.attemptOutput(generation:token,recovery:recovery,retries:retries)
        }
        pending=work;queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func attemptOutput(generation token: UInt64,recovery: UInt64,retries: Int) {
        guard running,generation == token,recoveryRevision == recovery,pipeline == nil else { return }
        outputRevision &+= 1
        let revision=outputRevision
        do {
            let output=try makeOutput(muted ? 0 : volume) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self,self.running,self.generation == token,self.outputRevision == revision,self.pipeline != nil else { return }
                    self.beginRecovery(delay:self.routeDelay)
                }
            }
            pipeline=output;starts += 1;status = .playing
            log("Audio output ready: \(output.device?.name ?? "system output"), \(output.sampleRate) Hz stereo.")
        } catch {
            if retries > 0 {
                status = .recovering
                scheduleAttempt(generation:token,recovery:recovery,retries:retries-1,delay:retryDelay)
            } else {
                status = .unavailable
                log("Audio output unavailable: \(error.localizedDescription). Waiting for a device change or Retry Audio.")
            }
        }
    }
    private func retireOutput() {
        outputRevision &+= 1
        guard let pipeline else { return }
        pipeline.stop()
        let stats=mystic_pcm_ring_stats(pipeline.render.ring)
        retired.rendered_frames += stats.rendered_frames;retired.dropped_frames += stats.dropped_frames
        retired.underrun_frames += stats.underrun_frames;discarded += UInt64(stats.queued_frames)
        self.pipeline=nil
    }
    private func stopLocked() {
        generation &+= 1;recoveryRevision &+= 1;running=false
        pending?.cancel();pending=nil;monitor.stop();retireOutput();status = .idle
    }
}

final class AudioRenderState: @unchecked Sendable {
    let ring: OpaquePointer
    init(initialGain: Float = 1) throws {
        guard let ring = mystic_pcm_ring_new(8192,2880) else { throw AudioPlaybackError("Unable to allocate audio ring.") }
        self.ring = ring
        // Initialize render-side gain before the real-time consumer starts. A muted new
        // route must not begin with the ring's default unity-to-zero ramp.
        mystic_pcm_ring_set_gain(ring,initialGain)
        var left: Float=0,right: Float=0
        _=mystic_pcm_ring_read(ring,&left,&right,0)
    }
    deinit { mystic_pcm_ring_free(ring) }
}
final class AudioPipeline: AudioOutputPipeline, @unchecked Sendable {
    let engine = AVAudioEngine()
    let render: AudioRenderState
    let source: AVAudioSourceNode
    var observer: NSObjectProtocol?
    private(set) var device: AudioOutputDevice?
    var sampleRate: Double { engine.isInManualRenderingMode ? engine.manualRenderingFormat.sampleRate : engine.outputNode.inputFormat(forBus:0).sampleRate }
    init(volume: Float, manualRendering: Bool = false,manualSampleRate: Double = 48000,
         configurationChanged: (@Sendable () -> Void)? = nil) throws {
        if !manualRendering { try AudioOutputMonitor.requireAvailableOutput() }
        let render = try AudioRenderState(initialGain:volume)
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
        if manualRendering {
            guard let output=AVAudioFormat(standardFormatWithSampleRate:manualSampleRate,channels:2) else {
                throw AudioPlaybackError("Unable to create offline output format.")
            }
            try engine.enableManualRenderingMode(.offline,format:output,maximumFrameCount:4096)
        }
        engine.attach(source)
        try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        mystic_pcm_ring_set_gain(render.ring,volume)
        engine.prepare()
        if let configurationChanged {
            observer=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { _ in configurationChanged() }
        }
        do {
            try engine.start()
            guard engine.isRunning else { throw AudioPlaybackError("The audio engine did not start.") }
            if !manualRendering { device=engine.outputNode.withAUAudioUnit { AudioOutputMonitor.describe($0.deviceID) } }
        } catch { stop();throw error }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        engine.stop()
    }
    deinit { stop() }
}
