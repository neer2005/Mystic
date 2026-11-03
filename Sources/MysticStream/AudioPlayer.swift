import Foundation
import AVFoundation
import AudioToolbox
import CMystic
import MysticKit
import MysticCore

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
    /// Packets whose time concealment had already played, skipped so latency does not grow.
    public let skippedLatePackets: UInt64
    public let decodeErrors: UInt64
    public let renderedFrames: UInt64
    public let queuedFrames: UInt32
    public let droppedFrames: UInt64
    public let underrunFrames: UInt64
    public let outputStatus: AudioOutputStatus
    public let outputDevice: String?
    public let outputSampleRate: Double?
    public let outputRestarts: UInt64
    public let outputLayout: String?
    public let stereoFallbackReason: String?
    public let discardedOutputFrames: UInt64
    /// What the PC sends this stream, once audio is set up.
    public let codec: AudioCodec?
}

protocol AudioOutputPipeline: AnyObject, Sendable {
    var render: AudioRenderState { get }
    var routing: AudioChannelRouting { get }
    var device: AudioOutputDevice? { get }
    var sampleRate: Double { get }
    /// How much the output reads at once, in 48 kHz frames; 0 when unknown.
    var outputFrames: Int { get }
    func stop()
}
extension AudioOutputPipeline { var outputFrames: Int { 0 } }

/// Serialized decode/control feeds a real-time SPSC reader. Device recovery never runs on the render thread.
public final class AudioPlayer: AudioConsumer, @unchecked Sendable {
    private let queue = DispatchQueue(label:"Mystic.Audio")
    private let log: @Sendable (String) -> Void
    /// The start of the packet trimmed last, which the next one fades in from.
    private var trimHead: [Float]=[]
    private let monitor: any AudioOutputMonitoring
    private let makeOutput: @Sendable (AudioSetupInfo,Float,String?,@escaping @Sendable () -> Void) throws -> any AudioOutputPipeline
    private let retryDelay: TimeInterval,routeDelay: TimeInterval
    private var decoder: (any StreamAudioDecoder)?
    private var pipeline: (any AudioOutputPipeline)?
    // Desired playback remains true while output is unavailable, so decoder state keeps advancing.
    private var running=false
    private var volume: Float=0.8,muted=false
    private var generation: UInt64=0,outputRevision: UInt64=0,recoveryRevision: UInt64=0
    private var pending: DispatchWorkItem?
    private var status: AudioOutputStatus = .idle
    private var starts: UInt64=0,discarded: UInt64=0
    private var retired=MysticPCMStats()
    private var decoded: UInt64=0,concealed: UInt64=0,errors: UInt64=0
    private var playout: AudioPlayout?
    private var lateTimer: DispatchSourceTimer?
    private let clock: @Sendable () -> UInt64
    private let concealTimer: Bool
    public convenience init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(monitor:AudioOutputRoute.makeMonitor(),makeOutput:{ info,gain,reason,changed in
            try AudioPipeline(volume:gain,info:info,forceStereoReason:reason,configurationChanged:changed)
        },log:log)
    }
    init(monitor: any AudioOutputMonitoring,
         makeOutput: @escaping @Sendable (AudioSetupInfo,Float,String?,@escaping @Sendable () -> Void) throws -> any AudioOutputPipeline,
         retryDelay: TimeInterval = 1,routeDelay: TimeInterval = 0.15,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },concealTimer: Bool = true,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.monitor=monitor;self.makeOutput=makeOutput;self.retryDelay=retryDelay;self.routeDelay=routeDelay;self.log=log
        self.clock=clock;self.concealTimer=concealTimer
    }
    deinit { pending?.cancel();lateTimer?.cancel();monitor.stop();pipeline?.stop() }
    public func setup(_ info: AudioSetupInfo) throws {
        try queue.sync {
            stopLocked();decoder=nil
            decoded=0;concealed=0;errors=0;starts=0;discarded=0;retired=MysticPCMStats()
            decoder=try makeStreamAudioDecoder(info)
            playout=AudioPlayout(packetMs:Int(info.packetDurationMs))
            log("Audio setup: \(info.codec) \(info.channelCount) channels at \(info.sampleRate) Hz, \(info.samplesPerFrame) samples/packet")
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
            if concealTimer,let decoder {
                let timer=DispatchSource.makeTimerSource(queue:queue)
                let interval=DispatchTimeInterval.milliseconds(AudioPlayout.tickMs(packetMs:Int(decoder.info.packetDurationMs)))
                timer.schedule(deadline:.now()+interval,repeating:interval,leeway:.microseconds(500))
                timer.setEventHandler { [weak self] in self?.concealLateLocked() }
                timer.resume();lateTimer=timer
            }
        }
    }
    /// Fills the time of a late packet before the output runs dry (`AudioPlayout`).
    func concealLatePackets() { queue.sync { concealLateLocked() } }
    private func concealLateLocked() {
        guard running,let decoder,let pipeline else { return }
        let queued=Int(mystic_pcm_ring_stats(pipeline.render.ring).queued_frames)
        guard let packets=playout?.tick(queued:queued,nowNanos:clock()),packets > 0 else { return }
        for _ in 0..<packets {
            do { try decode(decoder,packet:nil);concealed += 1 }
            catch { errors += 1;if errors <= 3 { log("Audio concealment failed: \(error.localizedDescription)") };return }
        }
    }
    public func play(_ packet: UnsafeRawBufferPointer?) {
        queue.sync {
            guard running,let decoder else { return }
            let queued=pipeline.map { Int(mystic_pcm_ring_stats($0.render.ring).queued_frames) } ?? 0
            let lead: Int
            switch playout?.packet(lost:packet == nil,queued:queued,nowNanos:clock()) {
            case .play(let value): lead=value
            case .trim:
                trimHead=[]
                try? decoder.decode(packet,routing:pipeline?.routing) { samples,frames in
                    let channels=samples.count/max(1,frames)
                    trimHead=Array(samples.prefix(min(frames,48*AudioPlayout.fadeMs)*channels))
                }
                log(String(format:"Audio clock drift: trimmed a packet with %.1f ms queued.",Double(queued)/48))
                return
            default: return
            }
            if lead > 0,let pipeline { writeSilence(lead,pipeline.render);trimHead=[] }
            do {
                try decode(decoder,packet:packet,fades:true)
                if packet == nil { concealed += 1 } else { decoded += 1 }
            } catch {
                errors += 1
                if errors <= 3 || errors % 100 == 0 { log(error.localizedDescription) }
                if packet != nil {
                    do { try decode(decoder,packet:nil);concealed += 1 }
                    catch { if errors <= 3 { log("Audio concealment failed: \(error.localizedDescription)") } }
                }
            }
        }
    }
    /// Nightjar's lead on an empty queue: the cushion that keeps ordinary jitter from starving the output.
    private func writeSilence(_ frames: Int,_ render: AudioRenderState) {
        let silence=[Float](repeating:0,count:frames*render.channels)
        silence.withUnsafeBufferPointer { _=mystic_pcm_ring_write(render.ring,$0.baseAddress,UInt32(frames)) }
    }
    private func decode(_ decoder: any StreamAudioDecoder,packet: UnsafeRawBufferPointer?,fades: Bool = false) throws {
        try decoder.decode(packet,routing:pipeline?.routing) { samples,frames in
            guard let pipeline else { discarded += UInt64(frames);return }
            if fades,!trimHead.isEmpty {
                var faded=Array(samples)
                AudioPlayout.crossfade(from:trimHead,into:&faded,channels:pipeline.render.channels)
                trimHead=[]
                faded.withUnsafeBufferPointer { _=mystic_pcm_ring_write(pipeline.render.ring,$0.baseAddress,UInt32(frames)) }
            } else { _=mystic_pcm_ring_write(pipeline.render.ring,samples.baseAddress,UInt32(frames)) }
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
            return AudioPlaybackStats(decodedPackets:decoded,concealedPackets:concealed,skippedLatePackets:playout?.skipped ?? 0,decodeErrors:errors,
                renderedFrames:retired.rendered_frames+s.rendered_frames,queuedFrames:s.queued_frames,
                droppedFrames:retired.dropped_frames+s.dropped_frames,underrunFrames:retired.underrun_frames+s.underrun_frames,
                outputStatus:status,outputDevice:pipeline?.device?.name,
                outputSampleRate:sampleRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                outputRestarts:starts > 0 ? starts-1 : 0,outputLayout:pipeline?.routing.label,
                stereoFallbackReason:pipeline?.routing.fallbackReason,discardedOutputFrames:discarded,codec:decoder?.info.codec)
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
    private func attemptOutput(generation token: UInt64,recovery: UInt64,retries: Int,forceStereo: Bool = false) {
        guard running,let decoder,generation == token,recoveryRevision == recovery,pipeline == nil else { return }
        outputRevision &+= 1
        let revision=outputRevision
        do {
            let output=try makeOutput(decoder.info,muted ? 0 : volume,forceStereo ? "Multichannel playback could not start on this output" : nil) { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self,self.running,self.generation == token,self.outputRevision == revision,self.pipeline != nil else { return }
                    self.beginRecovery(delay:self.routeDelay)
                }
            }
            pipeline=output;starts += 1;status = .playing
            playout?.outputFrames=output.outputFrames
            if let limit=playout?.ringLimit { mystic_pcm_ring_set_max_queued(output.render.ring,UInt32(limit)) }
            log("Audio output ready: \(output.device?.name ?? "system output"), \(output.sampleRate) Hz · \(output.routing.label).")
        } catch {
            if decoder.info.channelCount > 2,!forceStereo {
                // A separate revision fences events queued by a failed surround graph.
                attemptOutput(generation:token,recovery:recovery,retries:retries,forceStereo:true)
                return
            }
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
        playout?.reset();trimHead=[]
        guard let pipeline else { return }
        pipeline.stop()
        let stats=mystic_pcm_ring_stats(pipeline.render.ring)
        retired.rendered_frames += stats.rendered_frames;retired.dropped_frames += stats.dropped_frames
        retired.underrun_frames += stats.underrun_frames;discarded += UInt64(stats.queued_frames)
        self.pipeline=nil
    }
    private func stopLocked() {
        generation &+= 1;recoveryRevision &+= 1;running=false
        pending?.cancel();pending=nil;lateTimer?.cancel();lateTimer=nil;monitor.stop();retireOutput();status = .idle
    }
}

final class AudioRenderState: @unchecked Sendable {
    let ring: OpaquePointer
    let channels: Int
    init(initialGain: Float = 1,channels: Int = 2) throws {
        guard (1...8).contains(channels),let ring=mystic_pcm_ring_new_channels(8192,2880,UInt32(channels)) else {
            throw AudioPlaybackError("Unable to allocate audio ring.")
        }
        self.ring=ring;self.channels=channels
        mystic_pcm_ring_set_gain(ring,initialGain)
        // Prime gain before the render thread owns the ring; zero frames touch no PCM.
        var zero: Float=0
        withUnsafeMutablePointer(to:&zero) { pointer in
            var planes=(pointer,pointer,pointer,pointer,pointer,pointer,pointer,pointer)
            withUnsafeBytes(of:&planes) { bytes in
                _=mystic_pcm_ring_read_planar(ring,bytes.bindMemory(to:UnsafeMutablePointer<Float>?.self).baseAddress,UInt32(channels),0)
            }
        }
    }
    /// Only fixed stack storage and the C reader are used on the real-time thread.
    func read(_ buffers: UnsafeMutableAudioBufferListPointer,frames: UInt32) -> UInt32? {
        guard buffers.count == channels,frames <= 65_536 else { return nil }
        typealias Plane=UnsafeMutablePointer<Float>?
        var planes:(Plane,Plane,Plane,Plane,Plane,Plane,Plane,Plane)=(nil,nil,nil,nil,nil,nil,nil,nil)
        return withUnsafeMutableBytes(of:&planes) { bytes in
            let pointers=bytes.bindMemory(to:Plane.self)
            for channel in 0..<channels {
                let buffer=buffers[channel]
                guard buffer.mNumberChannels == 1,buffer.mDataByteSize/4 >= frames,let data=buffer.mData else { return nil }
                pointers[channel]=data.assumingMemoryBound(to:Float.self)
            }
            return mystic_pcm_ring_read_planar(ring,pointers.baseAddress,UInt32(channels),frames)
        }
    }
    deinit { mystic_pcm_ring_free(ring) }
}
final class AudioPipeline: AudioOutputPipeline, @unchecked Sendable {
    let engine: AVAudioEngine
    let render: AudioRenderState
    let source: AVAudioSourceNode
    let routing: AudioChannelRouting
    var observer: NSObjectProtocol?
    private(set) var device: AudioOutputDevice?
    var sampleRate: Double { engine.isInManualRenderingMode ? engine.manualRenderingFormat.sampleRate : engine.outputNode.inputFormat(forBus:0).sampleRate }
    /// The device's I/O buffer, in the stream's 48 kHz frames.
    var outputFrames: Int {
        guard !engine.isInManualRenderingMode,let frames=AudioOutputRoute.bufferFrames(engine),
              sampleRate > 0 else { return 0 }
        return Int((Double(frames)*48000/sampleRate).rounded(.up))
    }
    init(volume: Float,info: AudioSetupInfo = AudioSetupInfo(channelCount:2,channelMask:3,packetDurationMs:5,samplesPerFrame:240),
         manualRendering: Bool = false,manualSampleRate: Double = 48000,manualSpeakers: [AudioSpeaker]? = nil,
         forceStereoReason: String? = nil,
         configurationChanged: (@Sendable () -> Void)? = nil) throws {
        if !manualRendering { try AudioOutputRoute.requireAvailableOutput() }
        let engine=AVAudioEngine();self.engine=engine
        let destination: AudioSpeakerLayout?
        let targetRate: Double
        if manualRendering {
            destination=manualSpeakers.flatMap(AudioSpeakerLayout.configured)
            targetRate=manualSampleRate
        } else {
            let hardware=engine.outputNode.inputFormat(forBus:0)
            destination=AudioOutputRoute.speakers(engine,hardware:hardware)
            targetRate=hardware.sampleRate
        }
        let routing=try AudioChannelRouting(channelCount:Int(info.channelCount),channelMask:info.channelMask,
            destination:forceStereoReason == nil ? destination?.speakers : nil,fallbackReason:forceStereoReason)
        self.routing=routing
        let render=try AudioRenderState(initialGain:volume,channels:routing.outputChannels);self.render=render
        let layout=routing.isDiscrete ? destination!.layout : AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_Stereo)!
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channelLayout:layout)
        source=AVAudioSourceNode(format:format) { [render] silence,_,count,list in
            let buffers=UnsafeMutableAudioBufferListPointer(list)
            guard let read=render.read(buffers,frames:count) else {
                for buffer in buffers { if let data=buffer.mData { memset(data,0,Int(buffer.mDataByteSize)) } }
                silence.pointee=true;return kAudio_ParamError
            }
            silence.pointee=ObjCBool(read == 0);return noErr
        }
        if manualRendering {
            let outputLayout=destination?.layout ?? AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_Stereo)!
            let output=AVAudioFormat(standardFormatWithSampleRate:targetRate,channelLayout:outputLayout)
            try engine.enableManualRenderingMode(.offline,format:output,maximumFrameCount:4096)
        }
        engine.attach(source)
        try engine.connectNode(source,to:engine.mainMixerNode,format:format)
        if routing.isDiscrete {
            // Identical source/output speaker order avoids implicit surround remapping or upmixing.
            let output=AVAudioFormat(standardFormatWithSampleRate:targetRate,channelLayout:layout)
            try engine.connectNode(engine.mainMixerNode,to:engine.outputNode,format:output)
        }
        engine.prepare()
        if let configurationChanged {
            observer=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { _ in configurationChanged() }
        }
        do {
            try engine.start()
            guard engine.isRunning else { throw AudioPlaybackError("The audio engine did not start.") }
            if !manualRendering { device=AudioOutputRoute.describe(engine) }
        } catch { stop();throw error }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer);self.observer=nil }
        engine.stop()
    }
    deinit { stop() }
}
