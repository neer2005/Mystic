import AVFoundation
import CMystic
import Foundation

/// Lifecycle, conversion, encoding and send are confined to the session worker.
/// The hardware callback only copies borrowed float PCM into a bounded C ring.
public final class MicrophoneCapture: @unchecked Sendable {
    private let queue: DispatchQueue
    private let send: (UnsafeRawBufferPointer) throws -> Void
    private let report: @Sendable (String) -> Void
    private var engine: AVAudioEngine?
    private var ingress: MicIngress?
    private var sink: AVAudioSinkNode?
    private var encoder: MicrophoneEncoder?
    private var timer: (any DispatchSourceTimer)?
    private var observer: NSObjectProtocol?
    private var sent: UInt64=0
    private var ticks=0
    private var muted=false
    public init(queue: DispatchQueue,send: @escaping (UnsafeRawBufferPointer) throws -> Void,
                report: @escaping @Sendable (String) -> Void) { self.queue=queue;self.send=send;self.report=report }
    public func start() throws {
        stop()
        // Input hardware is queried only after permission was granted by the app.
        let engine=AVAudioEngine()
        let node=engine.inputNode,format=node.outputFormat(forBus:0)
        guard format.sampleRate >= 8000,format.sampleRate <= 192000,format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw MicrophoneError("The default input has an unsupported audio format.")
        }
        let encoder=try MicrophoneEncoder(sampleRate:format.sampleRate)
        let ingress=try MicIngress(maxQueued:UInt32(max(960,format.sampleRate/10)))
        let sink=AVAudioSinkNode { _,frames,buffers in
            let list=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:buffers))
            guard let first=list.first,let data=first.mData,first.mNumberChannels > 0,
                  UInt64(first.mDataByteSize) >= UInt64(frames)*UInt64(first.mNumberChannels)*4 else { return 0 }
            mystic_mic_write(ingress.handle,data.assumingMemoryBound(to:Float.self),frames,first.mNumberChannels)
            return 0
        }
        engine.attach(sink);try engine.connectNode(node,to:sink,format:format)
        self.engine=engine;self.ingress=ingress;self.sink=sink;self.encoder=encoder
        mystic_mic_mute(ingress.handle,muted)
        do { try engine.start() } catch { stop();throw error }
        observer=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { [weak self,weak engine] _ in
            guard let self else { return }
            self.queue.async { [weak self,weak engine] in
                guard let self,let engine,self.engine === engine else { return }
                do { try self.start() } catch { self.stop();self.report("Mic stopped after input change: \(error.localizedDescription)") }
            }
        }
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(10),leeway:.milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() };self.timer=timer;timer.resume()
        report(muted ? "Microphone muted" : "Microphone live · encrypted to host")
    }
    public func setMuted(_ value: Bool) {
        muted=value;encoder?.reset()
        if let ingress { mystic_mic_mute(ingress.handle,value) }
        guard engine != nil else { report("Microphone stopped. Reconnect to retry.");return }
        report(value ? "Microphone muted" : "Microphone live · encrypted to host")
    }
    public func stop() {
        timer?.setEventHandler {};timer?.cancel();timer=nil
        if let observer { NotificationCenter.default.removeObserver(observer);self.observer=nil }
        engine?.stop()
        if let sink { engine?.detach(sink) }
        sink=nil;engine=nil;ingress=nil;encoder=nil
    }
    deinit { stop() }
    private func poll() {
        guard !muted,let ingress,let encoder else { return }
        do {
            sent &+= UInt64(try encoder.drain(ingress.handle,send:send))
            ticks+=1
            if ticks % 100 == 0 { report("Microphone live · \(sent) encrypted packets sent") }
        } catch { stop();report("Microphone stopped: \(error.localizedDescription)") }
    }
}
final class MicIngress: @unchecked Sendable {
    let handle: OpaquePointer
    init(maxQueued: UInt32) throws {
        guard let handle=mystic_mic_new(maxQueued) else { throw MicrophoneError("Could not create microphone encoder.") };self.handle=handle
    }
    deinit { mystic_mic_free(handle) }
}
private struct MicrophoneError: LocalizedError { let message: String;init(_ message: String) { self.message=message };var errorDescription: String? { message } }

/// Worker-only processing, independently testable without opening an input device.
final class MicrophoneEncoder {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let nativeFrames: UInt32
    private var accumulated=[Float](repeating:0,count:960)
    private var used=0
    private var packet=[UInt8](repeating:0,count:1275)
    init(sampleRate: Double) throws {
        guard sampleRate >= 8000,sampleRate <= 192000,
              let mono=AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:1),
              let target=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1),
              let converter=AVAudioConverter(from:mono,to:target),
              let input=AVAudioPCMBuffer(pcmFormat:mono,frameCapacity:8192),
              let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:1920) else {
            throw MicrophoneError("Could not configure microphone conversion.")
        }
        self.converter=converter;self.input=input;self.output=output;nativeFrames=UInt32((sampleRate/50).rounded())
    }
    func reset() { used=0;converter.reset() }
    func drain(_ mic: OpaquePointer,send: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        guard let samples=input.floatChannelData?[0] else { return 0 }
        var packets=0
        for _ in 0..<4 {
            guard mystic_mic_read(mic,samples,nativeFrames) == nativeFrames else { break }
            input.frameLength=nativeFrames;output.frameLength=0
            var supplied=false,error: NSError?
            let status=converter.convert(to:output,error:&error) { _,state in
                if supplied { state.pointee = .noDataNow;return nil }
                supplied=true;state.pointee = .haveData;return input
            }
            if status == .error { throw error ?? MicrophoneError("Audio conversion failed.") as NSError }
            guard let converted=output.floatChannelData?[0] else { throw MicrophoneError("No converted microphone samples.") }
            for index in 0..<Int(output.frameLength) {
                accumulated[used]=converted[index];used+=1
                if used == 960 {
                    let n=accumulated.withUnsafeBufferPointer { pcm in
                        packet.withUnsafeMutableBufferPointer { bytes in mystic_mic_encode(mic,pcm.baseAddress,960,bytes.baseAddress,bytes.count) }
                    }
                    guard n > 0 else { throw MicrophoneError("Opus encoding failed (\(n)).") }
                    try packet.withUnsafeBytes { try send(UnsafeRawBufferPointer(rebasing:$0.prefix(Int(n)))) }
                    packets+=1;used=0
                }
            }
        }
        return packets
    }
}
