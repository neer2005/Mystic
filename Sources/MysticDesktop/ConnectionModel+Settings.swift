import Foundation
import MysticCore

/// Saved stream settings, read and written through `AppSettings` so they persist.
extension ConnectionModel {
    public var resolution: String {
        get { settings.value.resolution }
        set { settings.update { $0.resolution=newValue } }
    }
    public var fps: UInt32 {
        get { settings.value.fps }
        set { settings.update { $0.fps=newValue } }
    }
    public var bitrateMbps: Int32 {
        get { settings.value.bitrateMbps }
        set { settings.update { $0.bitrateMbps=newValue } }
    }
    public var hdr: Bool {
        get { settings.value.hdr }
        set { settings.update { $0.hdr=newValue } }
    }
    public var codec: String {
        get { settings.value.codec }
        set { settings.update { $0.codec=newValue } }
    }
    public var framePacing: FramePacingMode {
        get { FramePacingMode(rawValue:settings.value.framePacing ?? "") ?? .lowLatency }
        set { settings.update { $0.framePacing=newValue.rawValue } }
    }
    public var audioLayout: String {
        get { settings.value.audioLayout }
        set { settings.update { $0.audioLayout=newValue } }
    }
    public var volume: Float {
        get { settings.value.volume }
        set { settings.update { $0.volume=newValue };audioPlayer?.setVolume(volume,muted:muted) }
    }
    public var muted: Bool {
        get { settings.value.muted }
        set { settings.update { $0.muted=newValue };audioPlayer?.setVolume(volume,muted:muted) }
    }
    public var showLatencyHUD: Bool {
        get { settings.value.showLatencyHUD }
        set { settings.update { $0.showLatencyHUD=newValue } }
    }
    public var microphoneEnabled: Bool {
        get { settings.value.microphoneEnabled ?? false }
        set { settings.update { $0.microphoneEnabled=newValue } }
    }
    public var clipboardSync: Bool {
        get { settings.value.clipboardSync ?? false }
        set { settings.update { $0.clipboardSync=newValue } }
    }
    public var automaticReconnect: Bool {
        get { settings.value.automaticReconnect ?? true }
        set { settings.update { $0.automaticReconnect=newValue } }
    }
    public var adaptiveBitrate: Bool {
        get { settings.value.adaptiveBitrate ?? false }
        set { settings.update { $0.adaptiveBitrate=newValue } }
    }
}
