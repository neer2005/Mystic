import AVFoundation
import Foundation

/// Where the stream's sound plays, in each platform's terms. macOS picks a Core Audio device and
/// its speaker layout from Audio MIDI Setup. iOS has no device to pick: the system owns the route
/// (speaker, headphones, AirPlay, HDMI) through `AVAudioSession`, which the app must set up and
/// activate before an engine runs.
enum AudioOutputRoute {
    static func makeMonitor() -> any AudioOutputMonitoring {
        #if os(macOS)
        return AudioOutputMonitor()
        #else
        return AudioSessionMonitor()
        #endif
    }

    /// Throws when nothing can play; on iOS this also activates the audio session.
    static func requireAvailableOutput() throws {
        #if os(macOS)
        try AudioOutputMonitor.requireAvailableOutput()
        #else
        try AudioSessionPolicy.activate()
        guard !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty else {
            throw AudioPlaybackError("No audio output is connected.")
        }
        #endif
    }

    /// A named 5.1 or 7.1 speaker layout for discrete surround, or nil for stereo.
    static func speakers(_ engine: AVAudioEngine,hardware: AVAudioFormat) -> AudioSpeakerLayout? {
        #if os(macOS)
        let id=engine.outputNode.withAUAudioUnit { $0.deviceID }
        return AudioSpeakerLayout.device(id,channels:hardware.channelCount) ?? hardware.channelLayout.flatMap(AudioSpeakerLayout.init)
        #else
        // HDMI and AirPlay surround report their layout on the output format.
        return hardware.channelLayout.flatMap(AudioSpeakerLayout.init)
        #endif
    }

    /// How much the output reads at once, in its own frames.
    static func bufferFrames(_ engine: AVAudioEngine) -> Int? {
        #if os(macOS)
        return AudioOutputMonitor.bufferFrames(engine.outputNode.withAUAudioUnit { $0.deviceID })
        #else
        let session=AVAudioSession.sharedInstance()
        let frames=Int((session.ioBufferDuration*session.sampleRate).rounded())
        return (1...16384).contains(frames) ? frames : nil
        #endif
    }

    static func describe(_ engine: AVAudioEngine) -> AudioOutputDevice? {
        #if os(macOS)
        return engine.outputNode.withAUAudioUnit { AudioOutputMonitor.describe($0.deviceID) }
        #else
        return AVAudioSession.sharedInstance().currentRoute.outputs.first.map { AudioOutputDevice(id:0,name:$0.portName) }
        #endif
    }
}

#if !os(macOS)
/// The iOS audio session for a stream. Playback alone keeps Bluetooth headphones on their
/// high-quality link and the speaker as the output; the microphone needs play-and-record, routed
/// to the speaker rather than the earpiece and keeping A2DP where it can. The I/O buffer asked
/// for is 5 ms, one Opus packet, as small as the system will give: a longer one is delay.
enum AudioSessionPolicy {
    nonisolated(unsafe) private static var microphone=false
    private static let lock=NSLock()

    static func activate() throws {
        let wantsMicrophone=lock.withLock { microphone }
        let session=AVAudioSession.sharedInstance()
        if wantsMicrophone {
            try session.setCategory(.playAndRecord,mode:.default,options:[.defaultToSpeaker,.allowBluetoothA2DP])
        } else {
            try session.setCategory(.playback,mode:.default,options:[])
        }
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }

    /// The microphone starts: the session records from now on.
    static func setMicrophone(_ on: Bool) throws {
        lock.withLock { microphone=on }
        try activate()
    }
    /// The microphone stopped. The session keeps recording until the next activation: changing
    /// the category now would restart the stream's output mid-stream.
    static func microphoneStopped() { lock.withLock { microphone=false } }
}

/// Route changes (headphones in or out, AirPlay) and a reset of the media services, which ends
/// every engine, as the Mac's device and default-output changes.
final class AudioSessionMonitor: AudioOutputMonitoring, @unchecked Sendable {
    private var observers: [NSObjectProtocol]=[]
    func start(changed: @escaping @Sendable () -> Void) throws {
        stop()
        let center=NotificationCenter.default,session=AVAudioSession.sharedInstance()
        for name in [AVAudioSession.routeChangeNotification,AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName:name,object:session,queue:nil) { _ in changed() })
        }
    }
    func refresh() throws {}
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    deinit { stop() }
}
#endif
