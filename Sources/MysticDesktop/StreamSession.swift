import Foundation
import MysticKit
import MysticStream

/// Owns one engine on one worker queue. Interrupt may be called while start blocks;
/// stop/free are serialized after start returns. A fresh instance is used on reconnect.
final class StreamSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mystic.StreamSession")
    private let engine: StreamingEngine
    init() throws { engine = try StreamingEngine() }
    func start(host: String, launch: LaunchedStream, configuration: StreamConfiguration,
               decoder: VideoToolboxDecoder, audio: AudioPlayer, event: @escaping @Sendable (EngineEvent) -> Void,
               failure: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                guard let version = launch.appVersion else { throw HostConnectionError("The host did not report its application version.") }
                try engine.start(host: host, appVersion: version, rtspSessionURL: launch.rtspURL,
                    serverCodecModeSupport: launch.codecSupport, configuration: configuration,
                    video: decoder, audio: audio, onEvent: event)
            } catch { failure(String(describing: error)) }
        }
    }
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        engine.interrupt()
        queue.async { [self] in engine.stop(); completion() }
    }
}
