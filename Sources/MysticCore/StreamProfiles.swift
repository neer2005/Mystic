public import Foundation

/// Only launch-time video choices belong in a profile. Permissions and live audio remain global.
public struct StreamVideoSettings: Codable, Equatable, Sendable {
    public var resolution: String
    public var fps: UInt32
    public var bitrateMbps: Int32
    public var codec: String
    public var hdr: Bool
    /// Missing in older documents; off, as Nightjar.
    public var tenBitSDR: Bool
    public var preferYUV444: Bool
    public var framePacing: FramePacingMode
    public var adaptiveBitrate: Bool
    /// Missing in older documents; off.
    public var automaticQuality: AutomaticQuality
    /// Missing in older documents; Nightjar's 720 lines and 30 fps.
    public var qualityMinShortEdge: UInt32
    public var qualityMinFps: UInt32
    /// Missing in older documents; the PC's own displays, at Nightjar's defaults.
    public var virtualDisplay: Bool
    public var hostDisplay: HostDisplayMode
    public var renderScalePercent: Int
    public var displayScalePercent: Int
    public init(preferences: StreamPreferences = StreamPreferences()) {
        let value=preferences.validated()
        resolution=value.resolution;fps=value.fps;bitrateMbps=value.bitrateMbps
        codec=value.codec;hdr=value.hdr;tenBitSDR=value.tenBitSDR ?? false;preferYUV444=value.preferYUV444 ?? false
        framePacing=FramePacingMode(rawValue:value.framePacing ?? "") ?? .lowLatency
        adaptiveBitrate=value.adaptiveBitrate ?? false
        automaticQuality=AutomaticQuality(rawValue:value.automaticQuality ?? "") ?? .off
        qualityMinShortEdge=value.qualityMinShortEdge ?? 720
        qualityMinFps=value.qualityMinFps ?? 30
        virtualDisplay=value.virtualDisplay ?? false
        hostDisplay=HostDisplayMode(rawValue:value.hostDisplay ?? "") ?? .hostDefault
        renderScalePercent=value.renderScalePercent ?? 100
        displayScalePercent=value.displayScalePercent ?? 0
    }
    private enum CodingKeys: String, CodingKey { case resolution,fps,bitrateMbps,codec,hdr,tenBitSDR,preferYUV444,framePacing,adaptiveBitrate,automaticQuality,qualityMinShortEdge,qualityMinFps,virtualDisplay,hostDisplay,renderScalePercent,displayScalePercent }
    public init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        resolution=try c.decode(String.self,forKey:.resolution);fps=try c.decode(UInt32.self,forKey:.fps)
        bitrateMbps=try c.decode(Int32.self,forKey:.bitrateMbps);codec=try c.decode(String.self,forKey:.codec)
        hdr=try c.decode(Bool.self,forKey:.hdr);framePacing=try c.decode(FramePacingMode.self,forKey:.framePacing)
        adaptiveBitrate=try c.decode(Bool.self,forKey:.adaptiveBitrate)
        tenBitSDR=try c.decodeIfPresent(Bool.self,forKey:.tenBitSDR) ?? false
        preferYUV444=try c.decodeIfPresent(Bool.self,forKey:.preferYUV444) ?? false
        automaticQuality=try c.decodeIfPresent(AutomaticQuality.self,forKey:.automaticQuality) ?? .off
        qualityMinShortEdge=try c.decodeIfPresent(UInt32.self,forKey:.qualityMinShortEdge) ?? 720
        qualityMinFps=try c.decodeIfPresent(UInt32.self,forKey:.qualityMinFps) ?? 30
        virtualDisplay=try c.decodeIfPresent(Bool.self,forKey:.virtualDisplay) ?? false
        hostDisplay=(try? c.decodeIfPresent(HostDisplayMode.self,forKey:.hostDisplay)) ?? .hostDefault
        renderScalePercent=try c.decodeIfPresent(Int.self,forKey:.renderScalePercent) ?? 100
        displayScalePercent=try c.decodeIfPresent(Int.self,forKey:.displayScalePercent) ?? 0
    }
    /// What a stream asks the host for: Native and Display from this Mac's screen, read once at
    /// launch, and the recommended bitrate from the size and rate.
    public func mode(displayPixels: (width: UInt32,height: UInt32)?,displayHertz: Double?) -> StreamMode {
        let size=StreamPreferences.size(resolution) ?? StreamMode.fitted(displayPixels)
        let hertz=displayHertz.flatMap { $0.isFinite && $0 > 0 ? $0.rounded() : nil } ?? 60
        let range=StreamPreferences.customFrameRates
        let rate=fps == StreamPreferences.displayFrameRate ? UInt32(min(Double(range.upperBound),max(Double(range.lowerBound),hertz))) : fps
        let kbps=bitrateMbps == StreamPreferences.recommendedBitrate ? StreamMode.recommendedKbps(width:size.width,height:size.height,fps:rate) : bitrateMbps*1000
        return StreamMode(width:size.width,height:size.height,fps:rate,bitrateKbps:kbps)
    }
    public func validated() -> Self {
        var preferences=StreamPreferences();preferences.videoSettings=self
        return Self(preferences:preferences)
    }
    /// What a stream shown through `output` uses. Streams are kept to pictures the display can
    /// take straight from the renderer where they can be: macOS composites every frame of the
    /// notch-covering full screen, which the Metal HUD shows and which adds delay, so a
    /// full-display size becomes the size below the camera unless the notch mode is on. The saved
    /// choice is kept, so turning the mode on later brings it back. Native is limited where the
    /// screen is read. HDR stays as chosen: the Metal renderer tone maps it itself, so it goes
    /// direct to the display too (`HDRToneMap`).
    public func limited(to output: VideoOutput) -> Self {
        var value=self
        if !output.coversNotch,let below=StreamPreferences.belowCamera[resolution] { value.resolution=below }
        return value
    }
}

/// A stream's settled size, rate and bitrate.
public struct StreamMode: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let fps: UInt32
    public let bitrateKbps: Int32
    /// Nightjar's `default_bitrate_kbps`, from moonlight-qt: 20 Mbps at 1080p60, linear in
    /// pixels, with rates above 60 counting for less.
    public static func recommendedKbps(width: UInt32,height: UInt32,fps: UInt32) -> Int32 {
        let rate=Double(max(fps,1))/60,pixels=Double(max(width,1))*Double(max(height,1))
        let kbps=20_000*pixels/(1920*1080)*(rate <= 1 ? rate : rate.squareRoot())
        return Int32(min(150_000,max(2_000,kbps.rounded())))
    }
    /// A display's size within what a stream takes, keeping its shape; 1080p when unknown.
    static func fitted(_ pixels: (width: UInt32,height: UInt32)?) -> (width: UInt32,height: UInt32) {
        guard let pixels,pixels.width > 0,pixels.height > 0 else { return (1920,1080) }
        let scale=min(1,Double(StreamPreferences.customWidths.upperBound)/Double(pixels.width),
                      Double(StreamPreferences.customHeights.upperBound)/Double(pixels.height))
        func even(_ value: UInt32) -> UInt32 { UInt32((Double(value)*scale/2).rounded(.down))*2 }
        return (max(StreamPreferences.customWidths.lowerBound,even(pixels.width)),max(StreamPreferences.customHeights.lowerBound,even(pixels.height)))
    }
}

extension StreamPreferences {
    public var videoSettings: StreamVideoSettings {
        get { StreamVideoSettings(preferences:self) }
        set {
            resolution=newValue.resolution;fps=newValue.fps;bitrateMbps=newValue.bitrateMbps
            codec=newValue.codec;hdr=newValue.hdr;framePacing=newValue.framePacing.rawValue
            adaptiveBitrate=newValue.adaptiveBitrate
            tenBitSDR=newValue.tenBitSDR ? true : nil
            preferYUV444=newValue.preferYUV444 ? true : nil
            automaticQuality=newValue.automaticQuality == .off ? nil : newValue.automaticQuality.rawValue
            qualityMinShortEdge=newValue.qualityMinShortEdge == 720 ? nil : newValue.qualityMinShortEdge
            qualityMinFps=newValue.qualityMinFps == 30 ? nil : newValue.qualityMinFps
            virtualDisplay=newValue.virtualDisplay ? true : nil
            hostDisplay=newValue.hostDisplay == .hostDefault ? nil : newValue.hostDisplay.rawValue
            renderScalePercent=newValue.renderScalePercent == 100 ? nil : newValue.renderScalePercent
            displayScalePercent=newValue.displayScalePercent == 0 ? nil : newValue.displayScalePercent
        }
    }
}

public enum GameVideoSource: String, Codable, CaseIterable, Sendable {
    case host, global, custom
    public var label: String {
        switch self {
        case .host: return "Use host defaults"
        case .global: return "Use global defaults"
        case .custom: return "Custom game settings"
        }
    }
}

/// A bounded preference catalog, separate from pairing data and global preferences.
public struct StreamProfileCatalog: Equatable, Sendable {
    public static let hostCapacity=32,gameCapacity=256
    private struct GameProfile: Codable, Equatable, Sendable {
        let source: GameVideoSource
        let video: StreamVideoSettings?
    }
    private var hosts: [String:StreamVideoSettings] = [:]
    private var games: [String:[String:GameProfile]] = [:]
    private struct Document: Codable {
        let version: Int
        let hosts: [String:StreamVideoSettings]
        let games: [String:[String:GameProfile]]
    }
    public init() {}
    public init(data: Data) throws {
        guard data.count <= 1_048_576 else { throw ProfileError.invalidDocument }
        let document=try JSONDecoder().decode(Document.self,from:data)
        guard document.version == 1,document.hosts.count <= Self.hostCapacity,
              document.games.values.reduce(0,{ $0+$1.count }) <= Self.gameCapacity,
              document.games.count <= Self.gameCapacity else { throw ProfileError.invalidDocument }
        for (host,video) in document.hosts {
            try Self.validateKey(host);hosts[host]=video.validated()
        }
        for (host,entries) in document.games {
            try Self.validateKey(host)
            for (game,entry) in entries {
                try Self.validateKey(game)
                guard entry.source != .host,entry.source != .custom || entry.video != nil else { throw ProfileError.invalidDocument }
                games[host,default:[:]][game]=GameProfile(source:entry.source,video:entry.source == .custom ? entry.video?.validated() : nil)
            }
        }
    }
    public func encoded() throws -> Data {
        try JSONEncoder().encode(Document(version:1,hosts:hosts,games:games))
    }
    public func hostVideo(for host: String) -> StreamVideoSettings? { hosts[host] }
    public func source(host: String,game: String) -> GameVideoSource { games[host]?[game]?.source ?? .host }
    public func video(defaults: StreamVideoSettings,host: String?,game: String?) -> StreamVideoSettings {
        guard let host else { return defaults }
        if let game,let profile=games[host]?[game] {
            if profile.source == .global { return defaults }
            if let video=profile.video { return video }
        }
        return hosts[host] ?? defaults
    }
    public mutating func setHost(_ video: StreamVideoSettings?,host: String) throws {
        try Self.validateKey(host)
        guard video == nil || hosts[host] != nil || hosts.count < Self.hostCapacity else { throw ProfileError.capacity }
        hosts[host]=video?.validated()
    }
    public mutating func setGame(source: GameVideoSource,video: StreamVideoSettings?,host: String,game: String) throws {
        try Self.validateKey(host);try Self.validateKey(game)
        if source == .host {
            games[host]?[game]=nil
            if games[host]?.isEmpty == true { games[host]=nil }
            return
        }
        guard source != .custom || video != nil else { throw ProfileError.invalidDocument }
        guard games[host]?[game] != nil || games.values.reduce(0,{ $0+$1.count }) < Self.gameCapacity else { throw ProfileError.capacity }
        games[host,default:[:]][game]=GameProfile(source:source,video:source == .custom ? video?.validated() : nil)
    }
    private static func validateKey(_ key: String) throws {
        guard !key.isEmpty,key.utf8.count <= 512,!key.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw ProfileError.invalidDocument }
    }
    public enum ProfileError: Error { case invalidDocument,capacity }
}
