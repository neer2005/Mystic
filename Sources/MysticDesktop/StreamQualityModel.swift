import AppKit
import Foundation
import Observation
import MysticKit
import MysticCore

/// Nightjar's automatic quality during a stream: started once video is decoding, ticked after
/// each health tick, held while Mystic is not the active app, and stopped by a manual frame-rate
/// change or a size the host does not show.
@MainActor @Observable
public final class StreamQualityModel {
    public private(set) var status="Automatic quality off"
    /// The size and rate automatic quality last saw on screen; nil at the stream's own.
    public private(set) var current: (width: UInt32,height: UInt32,fpsMilliHz: UInt32)?
    @ObservationIgnored private var mode: AutomaticQuality = .off
    @ObservationIgnored private var started=false
    @ObservationIgnored private var finished=false
    @ObservationIgnored private unowned let model: ConnectionModel
    @ObservationIgnored var isFrontmost: () -> Bool = { NSApplication.shared.isActive }
    init(model: ConnectionModel) { self.model=model }

    /// Before each launch attempt: the ladder starts again at the stream's own size.
    func prepare(_ mode: AutomaticQuality) {
        self.mode=mode;started=false;finished=mode == .off;current=nil
        status=mode == .off ? "Automatic quality off" : "Automatic quality (\(mode.label.lowercased())): waiting for video…"
    }
    func reset() { prepare(.off) }

    func tick() async {
        guard !finished,model.phase == .streaming,model.hadVideo,let session=model.session else { return }
        let token=model.generation
        if !started {
            started=true
            switch await session.qualityBegin(mode) {
            case true?: status="Automatic quality (\(mode.label.lowercased())): at the stream's own size"
            case false?: finish("Automatic quality unavailable: this host does not accept size changes during a stream.")
            case nil: finish("Automatic quality could not start for this stream.")
            }
            return
        }
        let size=model.presenter?.videoSize ?? .zero
        guard let tick=await session.qualityTick(decodedWidth:UInt32(max(0,size.width.rounded())),
                                                 decodedHeight:UInt32(max(0,size.height.rounded())),suspended:!isFrontmost()),
              model.generation == token else { return }
        switch tick.state {
        case .off,.hold: break
        case .requested:
            guard let width=tick.width,let height=tick.height,let fps=tick.fpsMilliHz else { return }
            status="Automatic quality: asked the host for \(width)×\(height) at \(Self.rate(fps))…"
            model.decoder?.setLiveFrameRate((fps+999)/1000)
            model.recordStream("Automatic quality asked for \(width)×\(height) at \(Self.rate(fps)).")
        case .confirmed:
            guard let width=tick.width,let height=tick.height,let fps=tick.fpsMilliHz else { return }
            current=(width,height,fps)
            status="Automatic quality: \(width)×\(height) at \(Self.rate(fps))"
        case .stopped:
            finish(tick.reason ?? "Automatic quality stopped.")
        }
    }
    /// A manual frame-rate change owns the rate from here on.
    func manualFrameRateChanged() {
        guard !finished,mode != .off else { return }
        let session=model.session
        finish("Automatic quality stopped: the frame rate was changed by hand. It returns on reconnect.")
        Task { await session?.qualityEnd() }
    }
    private func finish(_ message: String) {
        finished=true;status=message
        if mode != .off { model.recordStream(message) }
    }
    static func rate(_ fpsMilliHz: UInt32) -> String {
        fpsMilliHz % 1000 == 0 ? "\(fpsMilliHz/1000) fps" : String(format:"%.2f fps",Double(fpsMilliHz)/1000)
    }
}
