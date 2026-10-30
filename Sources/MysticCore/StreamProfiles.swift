public import Foundation

/// Only launch-time video choices belong in a profile. Permissions and live audio remain global.
public struct StreamVideoSettings: Codable, Equatable, Sendable {
    public var resolution: String
    public var fps: UInt32
    public var bitrateMbps: Int32
    public var codec: String
    public var hdr: Bool
    public var framePacing: FramePacingMode
    public var adaptiveBitrate: Bool
    public init(preferences: StreamPreferences = StreamPreferences()) {
        let value=preferences.validated()
        resolution=value.resolution;fps=value.fps;bitrateMbps=value.bitrateMbps
        codec=value.codec;hdr=value.hdr
        framePacing=FramePacingMode(rawValue:value.framePacing ?? "") ?? .lowLatency
        adaptiveBitrate=value.adaptiveBitrate ?? false
    }
    public func validated() -> Self {
        var preferences=StreamPreferences();preferences.videoSettings=self
        return Self(preferences:preferences)
    }
}

extension StreamPreferences {
    public var videoSettings: StreamVideoSettings {
        get { StreamVideoSettings(preferences:self) }
        set {
            resolution=newValue.resolution;fps=newValue.fps;bitrateMbps=newValue.bitrateMbps
            codec=newValue.codec;hdr=newValue.hdr;framePacing=newValue.framePacing.rawValue
            adaptiveBitrate=newValue.adaptiveBitrate
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
