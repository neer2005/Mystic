public import Foundation
#if canImport(CoreGraphics)
public import CoreGraphics
#endif

/// Shared defaults, never connection credentials or live-session state.
public struct StreamPreferences: Codable, Equatable, Sendable {
    /// `nativeResolution` or "WIDTHxHEIGHT".
    public var resolution = Self.nativeResolution
    /// `displayFrameRate` or frames per second.
    public var fps: UInt32 = Self.displayFrameRate
    /// `recommendedBitrate` or megabits per second.
    public var bitrateMbps: Int32 = Self.recommendedBitrate
    public var codec = "auto"
    public var framePacing: String? = nil // Missing in older documents; defaults to low latency.
    public var hdr = false
    public var audioLayout = "stereo"
    public var volume: Float = 0.8
    public var muted = false
    public var automaticReconnect: Bool? = nil // Missing in older documents; defaults on.
    public var adaptiveBitrate: Bool? = nil // Missing in older documents; defaults off.
    public var automaticQuality: String? = nil // Missing in older documents; defaults off.
    public var qualityMinShortEdge: UInt32? = nil // Missing in older documents; 720, as Nightjar.
    public var qualityMinFps: UInt32? = nil // Missing in older documents; 30, as Nightjar.
    public var virtualDisplay: Bool? = nil // Missing in older documents; defaults off.
    public var hostDisplay: String? = nil // Missing in older documents; the PC's own setting.
    public var renderScalePercent: Int? = nil // Missing in older documents; 100, as Nightjar.
    public var displayScalePercent: Int? = nil // Missing in older documents; the PC's own.
    public var videoSizing: String? = nil // Missing in older documents; Fit, as Nightjar.
    public var alignVideoTop: Bool? = nil // Missing in older documents; defaults off.
    public var playAudioOnHost: Bool? = nil // Missing in older documents; defaults off.
    public var input: InputPreferences? = nil // Missing in older documents; Nightjar's defaults.
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
    public var quickResume: Bool? = nil // Missing in older documents; defaults off, as Nightjar.
    public var showLatencyHUD = false
    public var overlayMode: String? = nil // Missing in older documents; Compact, as Nightjar.
    public var libraryLayout = "grid"
    public var librarySort = "name"
    public var discoveryEnabled = true
    public var settingsPane = "general"
    public init() {}
    public static let nativeResolution="native"
    public static let displayFrameRate: UInt32=0
    public static let recommendedBitrate: Int32=0
    /// Nightjar's resolution menu after Native, with the MacBook Pro panels; Custom takes any other.
    public static let resolutions = ["640x360","854x480","1280x720","1366x768","1600x900","1920x1080","2560x1440","3840x2160",
                                     "1280x800","1920x1200","2560x1600","3840x2400",
                                     "2560x1080","3440x1440","5120x1440",
                                     "3024x1890","3024x1964","3456x2234"]
    /// Nightjar's frame rate menu after Display; Custom takes any rate in `customFrameRates`.
    public static let frameRates: [UInt32]=[30,60,90,120,144,165,240]
    public static let customFrameRates: ClosedRange<UInt32>=10...500
    public static let customWidths: ClosedRange<UInt32>=320...7680
    public static let customHeights: ClosedRange<UInt32>=240...4320
    /// Whole megabits; Nightjar's lowest choice of 0.5 Mbps is not offered.
    public static let bitrates: ClosedRange<Int32>=1...2000
    /// A size within the custom bounds; nil for Native or anything else.
    public static func size(_ resolution: String) -> (width: UInt32,height: UInt32)? {
        let parts=resolution.split(separator:"x",omittingEmptySubsequences:false)
        guard parts.count == 2,let width=UInt32(parts[0]),let height=UInt32(parts[1]),
              customWidths.contains(width),customHeights.contains(height) else { return nil }
        return (width,height)
    }
    /// The pixel size alone, for pickers and summaries.
    public static func resolutionLabel(_ resolution: String) -> String {
        resolution == nativeResolution ? "Native" : resolution.replacingOccurrences(of:"x",with:" × ")
    }
    public static func frameRateLabel(_ fps: UInt32) -> String { fps == displayFrameRate ? "Display" : "\(fps) fps" }
    public static func bitrateLabel(_ mbps: Int32) -> String { mbps == recommendedBitrate ? "Recommended" : "\(mbps) Mbps" }
    /// What a resolution is for, shown as secondary text beside its size.
    public static func resolutionDetail(_ resolution: String) -> String? {
        switch resolution {
        case nativeResolution: "This Mac's display"
        case "640x360": "360p · 16:9"
        case "854x480": "480p · 16:9"
        case "1280x720": "720p · 16:9"
        case "1366x768": "Laptop · 16:9"
        case "1600x900": "900p · 16:9"
        case "1920x1080": "1080p · 16:9"
        case "2560x1440": "1440p · 16:9"
        case "3024x1890": "MacBook Pro 14-inch below the camera · 16:10"
        case "3024x1964": "MacBook Pro 14-inch full display"
        case "3456x2234": "MacBook Pro 16-inch full display"
        case "3840x2160": "4K · 16:9"
        case "1280x800","1920x1200","2560x1600","3840x2400": "16:10"
        case "2560x1080","3440x1440": "Ultrawide · 21:9"
        case "5120x1440": "Super ultrawide · 32:9"
        default: nil
        }
    }
    public static let codecs = ["auto","h264","hevc","av1"]
    public func validated() -> Self {
        var value=self
        if value.resolution != Self.nativeResolution,Self.size(value.resolution) == nil { value.resolution=Self.nativeResolution }
        if value.fps != Self.displayFrameRate,!Self.customFrameRates.contains(value.fps) { value.fps=Self.displayFrameRate }
        value.bitrateMbps=value.bitrateMbps <= 0 ? Self.recommendedBitrate : min(Self.bitrates.upperBound,value.bitrateMbps)
        value.qualityMinShortEdge=value.qualityMinShortEdge.map { min(2160,max(256,$0)) }
        value.qualityMinFps=value.qualityMinFps.map { min(240,max(15,$0)) }
        if let mode=value.hostDisplay,HostDisplayMode(rawValue:mode) == nil { value.hostDisplay=nil }
        value.renderScalePercent=value.renderScalePercent.map { min(HostDisplayMode.renderScales.upperBound,max(HostDisplayMode.renderScales.lowerBound,$0)) }
        // A scale Windows does not offer would make the PC refuse the launch.
        if let scale=value.displayScalePercent,!HostDisplayMode.displayScales.contains(scale) { value.displayScalePercent=nil }
        if let mode=value.videoSizing,VideoSizing(rawValue:mode) == nil { value.videoSizing=nil }
        value.input=value.input?.validated()
        if let mode=value.framePacing,FramePacingMode(rawValue:mode) == nil { value.framePacing=nil }
        if !Self.codecs.contains(value.codec) { value.codec="auto" }
        if !["stereo","5.1","7.1"].contains(value.audioLayout) { value.audioLayout="stereo" }
        value.volume=value.volume.isFinite ? min(1,max(0,value.volume)) : 0.8
        if !["grid","list"].contains(value.libraryLayout) { value.libraryLayout="grid" }
        if !["name","host"].contains(value.librarySort) { value.librarySort="name" }
        if !["general","video","audio","controls","keyboard","network"].contains(value.settingsPane) { value.settingsPane="general" }
        if let seconds=value.networkGraceSeconds,NetworkGrace(rawValue:seconds) == nil { value.networkGraceSeconds=nil }
        if let choice=value.errorCorrection,ErrorCorrection(rawValue:choice) == nil { value.errorCorrection=nil }
        if let mode=value.overlayMode,OverlayMode(rawValue:mode) == nil || mode == OverlayMode.compact.rawValue { value.overlayMode=nil }
        if let mode=value.automaticQuality,AutomaticQuality(rawValue:mode) == nil || mode == AutomaticQuality.off.rawValue { value.automaticQuality=nil }
        return value
    }
}

/// What the PC does with its displays during a stream, as Nightjar's "Display arrangement". The
/// raw values are the launch's `hostDisplay`, which only hosts with display modes receive.
public enum HostDisplayMode: String, Codable, CaseIterable, Sendable {
    case hostDefault="default",exclusive,extendedPrimary="extended_primary",extended
    case extendedIsolated="extended_isolated",extendedPrimaryIsolated="extended_primary_isolated",physical
    public var label: String {
        switch self {
        case .hostDefault: "PC's Own Setting"
        case .exclusive: "Virtual Display Only"
        case .extendedPrimary: "Extend as Primary"
        case .extended: "Extend"
        case .extendedIsolated: "Extend, Isolated"
        case .extendedPrimaryIsolated: "Extend as Primary, Isolated"
        case .physical: "Physical Display"
        }
    }
    /// Nightjar's `requests_virtual_display`: the PC's own setting follows the switch.
    public func requestsVirtualDisplay(setting: Bool) -> Bool {
        switch self {
        case .hostDefault: setting
        case .physical: false
        default: true
        }
    }
    public static let renderScales=50...200
    /// 0 keeps the PC's own; the others are the scales Windows offers.
    public static let displayScales=[0,100,125,150,175,200,225,250,300,350,400,450,500]
}

/// Whether a host offers a feature, from what it reports about itself.
public enum HostFeatureAvailability: String, Codable, Sendable {
    case supported,unknown,never,update,off,driver
    /// Why a setting is turned off, for a host that could offer it; nil when it is on.
    public var note: String? {
        switch self {
        case .supported,.unknown,.never: nil
        case .update: "This host doesn't offer this yet."
        case .off: "Turn on the virtual display in the host's settings."
        case .driver: "The host's virtual display driver isn't ready."
        }
    }
    public var usable: Bool { self == .supported || self == .unknown }
}

/// What a host reports about its displays.
public struct HostDisplaySupport: Codable, Equatable, Sendable {
    public var virtualDisplay: HostFeatureAvailability
    public var modes: HostFeatureAvailability
    public var scale: HostFeatureAvailability
    public init(virtualDisplay: HostFeatureAvailability,modes: HostFeatureAvailability,scale: HostFeatureAvailability) {
        self.virtualDisplay=virtualDisplay;self.modes=modes;self.scale=scale
    }
}

/// How the picture fills the stream window, as Nightjar's "Video size".
public enum VideoSizing: String, Codable, CaseIterable, Sendable {
    case fit,fill,stretch,native
    public var label: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill (Crop)"
        case .stretch: "Stretch"
        case .native: "Native Pixels (1:1)"
        }
    }
    /// Where the video goes in a view with its origin at the bottom left. Fill and Native Pixels
    /// can overhang the view, which clips them; aligning to the top moves Fit and Native Pixels.
    public func rect(video: CGSize,in container: CGRect,pixelsPerPoint: CGFloat = 1,alignTop: Bool = false) -> CGRect {
        guard video.width > 0,video.height > 0,container.width > 0,container.height > 0,pixelsPerPoint > 0 else { return .zero }
        let widthScale=container.width/video.width,heightScale=container.height/video.height
        let size: CGSize
        switch self {
        case .fit: size=CGSize(width:video.width*min(widthScale,heightScale),height:video.height*min(widthScale,heightScale))
        case .fill: size=CGSize(width:video.width*max(widthScale,heightScale),height:video.height*max(widthScale,heightScale))
        case .stretch: return container
        case .native: size=CGSize(width:video.width/pixelsPerPoint,height:video.height/pixelsPerPoint)
        }
        let x: CGFloat=container.midX-size.width/2
        let y: CGFloat=alignTop && self != .fill ? container.maxY-size.height : container.midY-size.height/2
        return CGRect(x:x,y:y,width:size.width,height:size.height)
    }
}

/// Mouse and controller choices that apply at once, during a stream too. Nightjar's defaults,
/// except the dead zone: Nightjar leaves it to SDL's mapping, GameController gets Mystic's 12%.
public struct InputPreferences: Codable, Equatable, Sendable {
    public var mouseSpeedPercent=100
    public var mouseNavigationButtons=true
    public var controllers=true
    public var disableVibration=false
    public var swapFaceButtons=false
    public var controllerMotion=true
    public var stickDeadZonePercent=12
    public init() {}
    private enum CodingKeys: String, CodingKey { case mouseSpeedPercent,mouseNavigationButtons,controllers,disableVibration,swapFaceButtons,controllerMotion,stickDeadZonePercent }
    public init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mouseSpeedPercent=try c.decodeIfPresent(Int.self,forKey:.mouseSpeedPercent) ?? 100
        mouseNavigationButtons=try c.decodeIfPresent(Bool.self,forKey:.mouseNavigationButtons) ?? true
        controllers=try c.decodeIfPresent(Bool.self,forKey:.controllers) ?? true
        disableVibration=try c.decodeIfPresent(Bool.self,forKey:.disableVibration) ?? false
        swapFaceButtons=try c.decodeIfPresent(Bool.self,forKey:.swapFaceButtons) ?? false
        controllerMotion=try c.decodeIfPresent(Bool.self,forKey:.controllerMotion) ?? true
        stickDeadZonePercent=try c.decodeIfPresent(Int.self,forKey:.stickDeadZonePercent) ?? 12
    }
    public func validated() -> Self {
        var value=self
        value.mouseSpeedPercent=min(400,max(25,value.mouseSpeedPercent))
        value.stickDeadZonePercent=min(50,max(0,value.stickDeadZonePercent))
        return value
    }
    public var mouseScale: Double { Double(mouseSpeedPercent)/100 }
    public var stickDeadZone: Double { Double(stickDeadZonePercent)/100 }
}

/// The performance overlay's detail, as Nightjar's and Android's: Compact's one line behind a
/// health mark, Statistics' lines with the host's hardware, or Debug's every measurement.
public enum OverlayMode: String, Codable, CaseIterable, Sendable {
    case compact,statistics,debug
    public var label: String { switch self { case .compact: "Compact";case .statistics: "Statistics";case .debug: "Debug" } }
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
