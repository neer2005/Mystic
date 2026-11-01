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
    public var overlayMode: OverlayMode {
        get { OverlayMode(rawValue:settings.value.overlayMode ?? "") ?? .compact }
        set { settings.update { $0.overlayMode=newValue == .compact ? nil : newValue.rawValue } }
    }
    public var showLatencyHUD: Bool {
        get { settings.value.showLatencyHUD }
        set { settings.update { $0.showLatencyHUD=newValue } }
    }
    public var microphoneEnabled: Bool {
        get { settings.value.microphoneEnabled ?? false }
        set { settings.update { $0.microphoneEnabled=newValue } }
    }
    /// Nightjar's quick resume: choosing a PC that runs a game goes straight back into it.
    public var quickResume: Bool {
        get { settings.value.quickResume ?? false }
        set { settings.update { $0.quickResume=newValue } }
    }
    /// Look for a newer stable release once per launch.
    public var checkForUpdates: Bool {
        get { settings.value.checkForUpdates ?? true }
        set { settings.update { $0.checkForUpdates=newValue } }
    }
    /// Nightjar's "Local cursor": in desktop control, the host's cursor is the Mac pointer.
    public var localCursor: Bool {
        get { settings.value.localCursor ?? true }
        set { settings.update { $0.localCursor=newValue } }
    }
    public var clipboardSync: Bool {
        get { settings.value.clipboardSync ?? false }
        set { settings.update { $0.clipboardSync=newValue } }
    }
    public var automaticReconnect: Bool {
        get { settings.value.automaticReconnect ?? true }
        set { settings.update { $0.automaticReconnect=newValue } }
    }
    public var networkGrace: NetworkGrace {
        get { NetworkGrace(rawValue:settings.value.networkGraceSeconds ?? 0) ?? .off }
        set { settings.update { $0.networkGraceSeconds=newValue == .off ? nil : newValue.rawValue } }
    }
    public var errorCorrection: ErrorCorrection {
        get { ErrorCorrection(rawValue:settings.value.errorCorrection ?? "") ?? .host }
        set { settings.update { $0.errorCorrection=newValue == .host ? nil : newValue.rawValue } }
    }
    public var tellHostWireless: Bool {
        get { settings.value.tellHostWireless ?? true }
        set { settings.update { $0.tellHostWireless=newValue } }
    }
    public var tellHostLinkSpeed: Bool {
        get { settings.value.tellHostLinkSpeed ?? true }
        set { settings.update { $0.tellHostLinkSpeed=newValue } }
    }
    public var clientRoaming: Bool {
        get { settings.value.clientRoaming ?? true }
        set { settings.update { $0.clientRoaming=newValue } }
    }
    public var roamingOnMeteredNetworks: Bool {
        get { settings.value.roamingOnMeteredNetworks ?? false }
        set { settings.update { $0.roamingOnMeteredNetworks=newValue } }
    }
    public var videoSizing: VideoSizing {
        get { VideoSizing(rawValue:settings.value.videoSizing ?? "") ?? .fit }
        set { settings.update { $0.videoSizing=newValue == .fit ? nil : newValue.rawValue } }
    }
    public var alignVideoTop: Bool {
        get { settings.value.alignVideoTop ?? false }
        set { settings.update { $0.alignVideoTop=newValue } }
    }
    public var playAudioOnHost: Bool {
        get { settings.value.playAudioOnHost ?? false }
        set { settings.update { $0.playAudioOnHost=newValue } }
    }
    public var inputPreferences: InputPreferences {
        get { settings.value.input ?? InputPreferences() }
        set { settings.update { $0.input=newValue } }
    }
    public var adaptiveBitrate: Bool {
        get { settings.value.adaptiveBitrate ?? false }
        set { settings.update { $0.adaptiveBitrate=newValue } }
    }
}
