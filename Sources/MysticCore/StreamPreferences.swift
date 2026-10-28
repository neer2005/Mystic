import Foundation

/// Shared defaults, never connection credentials or live-session state.
public struct StreamPreferences: Codable, Equatable, Sendable {
    public var resolution = "1920x1080"
    public var fps: UInt32 = 60
    public var bitrateMbps: Int32 = 20
    public var codec = "auto"
    public var hdr = false
    public var audioLayout = "stereo"
    public var volume: Float = 0.8
    public var muted = false
    public var microphoneEnabled: Bool? = nil // Missing in older documents; defaults off.
    public var showLatencyHUD = false
    public var libraryLayout = "grid"
    public var librarySort = "name"
    public var discoveryEnabled = true
    public var settingsPane = "general"
    public init() {}
    public static let resolutions = ["1280x720","1920x1080","2560x1440","3024x1964","3456x2234","3840x2160"]
    public static func resolutionLabel(_ resolution: String) -> String {
        let dimensions=resolution.replacingOccurrences(of:"x",with:" × ")
        switch resolution {
        case "3024x1964": return "\(dimensions) (MacBook Pro 14-inch)"
        case "3456x2234": return "\(dimensions) (MacBook Pro 16-inch)"
        default:return dimensions
        }
    }
    public static let codecs = ["auto","h264","hevc","av1"]
    public func validated() -> Self {
        var value=self
        if !Self.resolutions.contains(value.resolution) { value.resolution="1920x1080" }
        if ![60,120].contains(value.fps) { value.fps=60 }
        value.bitrateMbps=min(150,max(5,value.bitrateMbps))
        if !Self.codecs.contains(value.codec) { value.codec="auto" }
        if !["stereo","5.1","7.1"].contains(value.audioLayout) { value.audioLayout="stereo" }
        value.volume=value.volume.isFinite ? min(1,max(0,value.volume)) : 0.8
        if !["grid","list"].contains(value.libraryLayout) { value.libraryLayout="grid" }
        if !["name","host"].contains(value.librarySort) { value.librarySort="name" }
        if !["general","video","audio","network"].contains(value.settingsPane) { value.settingsPane="general" }
        return value
    }
}
