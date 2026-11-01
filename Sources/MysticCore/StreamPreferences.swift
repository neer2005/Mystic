import Foundation

/// Shared defaults, never connection credentials or live-session state.
public struct StreamPreferences: Codable, Equatable, Sendable {
    public var resolution = "1920x1080"
    public var fps: UInt32 = 60
    public var bitrateMbps: Int32 = 20
    public var codec = "auto"
    public var framePacing: String? = nil // Missing in older documents; defaults to low latency.
    public var hdr = false
    public var audioLayout = "stereo"
    public var volume: Float = 0.8
    public var muted = false
    public var automaticReconnect: Bool? = nil // Missing in older documents; defaults on.
    public var adaptiveBitrate: Bool? = nil // Missing in older documents; defaults off.
    public var automaticQuality: String? = nil // Missing in older documents; defaults off.
    public var clipboardSync: Bool? = nil // Missing in older documents; defaults off.
    public var microphoneEnabled: Bool? = nil // Missing in older documents; defaults off.
    public var networkGraceSeconds: Int? = nil // Missing in older documents; defaults off.
    public var errorCorrection: String? = nil // Missing in older documents; defaults to the host's.
    public var tellHostWireless: Bool? = nil // Missing in older documents; defaults on.
    public var tellHostLinkSpeed: Bool? = nil // Missing in older documents; defaults on.
    public var clientRoaming: Bool? = nil // Missing in older documents; defaults on, as Nightjar.
    public var roamingOnMeteredNetworks: Bool? = nil // Missing in older documents; defaults off.
    public var localCursor: Bool? = nil // Missing in older documents; defaults on, as Nightjar.
    public var checkForUpdates: Bool? = nil // Missing in older documents; defaults on, as Nightjar.
    public var showLatencyHUD = false
    public var libraryLayout = "grid"
    public var librarySort = "name"
    public var discoveryEnabled = true
    public var settingsPane = "general"
    public init() {}
    public static let resolutions = ["1280x720","1920x1080","2560x1440","3024x1890","3024x1964","3456x2234","3840x2160"]
    /// The pixel size alone, for pickers and summaries.
    public static func resolutionLabel(_ resolution: String) -> String {
        resolution.replacingOccurrences(of:"x",with:" × ")
    }
    /// What a resolution is for, shown as secondary text beside its size.
    public static func resolutionDetail(_ resolution: String) -> String? {
        switch resolution {
        case "1280x720": "720p · 16:9"
        case "1920x1080": "1080p · 16:9"
        case "2560x1440": "1440p · 16:9"
        case "3024x1890": "MacBook Pro 14-inch below the camera · 16:10"
        case "3024x1964": "MacBook Pro 14-inch full display"
        case "3456x2234": "MacBook Pro 16-inch full display"
        case "3840x2160": "4K · 16:9"
        default: nil
        }
    }
    public static let codecs = ["auto","h264","hevc","av1"]
    public func validated() -> Self {
        var value=self
        if !Self.resolutions.contains(value.resolution) { value.resolution="1920x1080" }
        if ![60,120].contains(value.fps) { value.fps=60 }
        value.bitrateMbps=min(150,max(5,value.bitrateMbps))
        if let mode=value.framePacing,FramePacingMode(rawValue:mode) == nil { value.framePacing=nil }
        if !Self.codecs.contains(value.codec) { value.codec="auto" }
        if !["stereo","5.1","7.1"].contains(value.audioLayout) { value.audioLayout="stereo" }
        value.volume=value.volume.isFinite ? min(1,max(0,value.volume)) : 0.8
        if !["grid","list"].contains(value.libraryLayout) { value.libraryLayout="grid" }
        if !["name","host"].contains(value.librarySort) { value.librarySort="name" }
        if !["general","video","audio","network"].contains(value.settingsPane) { value.settingsPane="general" }
        if let seconds=value.networkGraceSeconds,NetworkGrace(rawValue:seconds) == nil { value.networkGraceSeconds=nil }
        if let choice=value.errorCorrection,ErrorCorrection(rawValue:choice) == nil { value.errorCorrection=nil }
        if let mode=value.automaticQuality,AutomaticQuality(rawValue:mode) == nil || mode == AutomaticQuality.off.rawValue { value.automaticQuality=nil }
        return value
    }
}

/// Nightjar's automatic quality: which way the stream gives way when this Mac or the network
/// cannot keep up. Each mode walks its own bounded resolution/frame-rate ladder.
public enum AutomaticQuality: String, Codable, CaseIterable, Sendable {
    case off,motion,detail,battery
    public var label: String {
        switch self {
        case .off: "Off"
        case .motion: "Favor Smooth Motion"
        case .detail: "Favor Sharp Detail"
        case .battery: "Favor Battery Life"
        }
    }
    /// The engine's `mystic_session_quality_begin` mode; 0 for off.
    public var engineValue: UInt8 {
        switch self {
        case .off: 0
        case .motion: 1
        case .detail: 2
        case .battery: 3
        }
    }
}

/// Nightjar's "Ride out network drops": how long a silent network may keep the stream.
public enum NetworkGrace: Int, CaseIterable, Sendable {
    case off=0,twentySeconds=20,thirtySeconds=30,sixtySeconds=60
    public var label: String { self == .off ? "Off" : "\(rawValue) Seconds" }
    /// Off keeps Nightjar's 3 s grace, below the connection's own 10 s timeout: no tolerance.
    public var milliseconds: UInt32 { self == .off ? 3000 : UInt32(rawValue)*1000 }
}

/// The share of video error correction to ask the host for.
public enum ErrorCorrection: String, CaseIterable, Sendable {
    case host,automatic="auto",ten="10",twenty="20",thirty="30",fifty="50"
    public var label: String {
        switch self {
        case .host: "Host's Setting"
        case .automatic: "Automatic"
        default: "\(rawValue)%"
        }
    }
    /// `MysticStreamConfig::video_fec`: -1 the host's, -2 automatic, otherwise the percentage.
    public var engineValue: Int16 {
        switch self {
        case .host: -1
        case .automatic: -2
        default: Int16(rawValue) ?? -1
        }
    }
}
