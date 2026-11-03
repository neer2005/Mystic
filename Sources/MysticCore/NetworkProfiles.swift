import Foundation

/// What kind of network a stream would run over, from the route toward the PC. Nightjar's
/// desktop client tells home Wi-Fi from other Wi-Fi by the network's name; macOS gives an app
/// that name only with Location Services, so Mystic tells home from away by the route itself:
/// a metered connection, a VPN or a PC outside the local network, then Wi-Fi or wired.
public enum NetworkKind: String, Codable, CaseIterable, Sendable {
    case metered,remote,wifi,wired
    public var label: String {
        switch self {
        case .metered: "Metered network (hotspot)"
        case .remote: "Away (VPN or remote address)"
        case .wifi: "Wi-Fi at home"
        case .wired: "Wired at home"
        }
    }
    /// Metered first, as Nightjar's mobile data; nil when the route is unknown.
    public static func of(metered: Bool,vpn: Bool,localHost: Bool,wireless: Bool?) -> Self? {
        if metered { return .metered }
        if vpn || !localHost { return .remote }
        return wireless.map { $0 ? .wifi : .wired }
    }
    /// Whether a host address is on the local network: private and link-local IPv4 and IPv6,
    /// `.local` names and single-label names. Tailscale's 100.64.0.0/10 is not.
    public static func isLocal(_ host: String) -> Bool {
        let name=host.trimmingCharacters(in:CharacterSet(charactersIn:"[]")).lowercased()
        let parts=name.split(separator:".").compactMap { UInt8($0) }
        if parts.count == 4 {
            return parts[0] == 10 || parts[0] == 127 || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
        }
        if name.contains(":") {
            return name == "::1" || name.hasPrefix("fe8") || name.hasPrefix("fe9") || name.hasPrefix("fea") || name.hasPrefix("feb")
                || name.hasPrefix("fc") || name.hasPrefix("fd")
        }
        return name.hasSuffix(".local") || (!name.isEmpty && !name.contains("."))
    }
}

/// The video settings a network profile changes; nil leaves the stream's own.
public struct VideoOverrides: Codable, Equatable, Sendable {
    public var resolution: String?
    public var fps: UInt32?
    public var bitrateMbps: Int32?
    public var codec: String?
    public var hdr: Bool?
    public var adaptiveBitrate: Bool?
    public var automaticQuality: AutomaticQuality?
    public init(resolution: String? = nil,fps: UInt32? = nil,bitrateMbps: Int32? = nil,codec: String? = nil,hdr: Bool? = nil,
                adaptiveBitrate: Bool? = nil,automaticQuality: AutomaticQuality? = nil) {
        self.resolution=resolution;self.fps=fps;self.bitrateMbps=bitrateMbps;self.codec=codec;self.hdr=hdr
        self.adaptiveBitrate=adaptiveBitrate;self.automaticQuality=automaticQuality
    }
    public var isEmpty: Bool { self == Self() }
    /// The overrides on top of what the global, host and game settings resolved to, validated.
    public func apply(to video: StreamVideoSettings) -> StreamVideoSettings {
        var next=video
        if let resolution { next.resolution=resolution }
        if let fps { next.fps=fps }
        if let bitrateMbps { next.bitrateMbps=bitrateMbps }
        if let codec { next.codec=codec }
        if let hdr { next.hdr=hdr }
        if let adaptiveBitrate { next.adaptiveBitrate=adaptiveBitrate }
        if let automaticQuality { next.automaticQuality=automaticQuality }
        return next.validated()
    }
    /// "1080p · 15 Mbps", for Stream Details.
    public var summary: String {
        var parts: [String]=[]
        if let resolution { parts.append(StreamPreferences.resolutionLabel(resolution)) }
        if let fps { parts.append(StreamPreferences.frameRateLabel(fps)) }
        if let bitrateMbps { parts.append(StreamPreferences.bitrateLabel(bitrateMbps)) }
        if let codec { parts.append(codec == "auto" ? "automatic codec" : codec.uppercased()) }
        if let hdr { parts.append(hdr ? "HDR" : "SDR") }
        if let adaptiveBitrate { parts.append(adaptiveBitrate ? "automatic bitrate" : "fixed bitrate") }
        if let automaticQuality { parts.append("quality: \(automaticQuality.label)") }
        return parts.isEmpty ? "no changes" : parts.joined(separator:" · ")
    }
}

/// Nightjar's settings profiles (`config.rs` `Profiles`): named changes to the stream settings,
/// one chosen by hand and, with automatic choice on, one per kind of network. Mystic's host and
/// game profiles are whole settings rather than changes, so a network profile applies on top of
/// them; otherwise a PC with its own profile would ignore the network.
public struct NetworkProfiles: Codable, Equatable, Sendable {
    public struct Profile: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        public var name: String
        public var overrides: VideoOverrides
    }
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description=description }
    }
    public static let maxProfiles=50
    public private(set) var entries: [Profile]=[]
    /// The profile chosen by hand: it applies where no rule picks one.
    public var active: Int?
    public var automatic=false
    public var rules: [NetworkKind:Int]=[:]
    public init() {}

    /// The profile for a stream over `kind` (nil when unknown): its rule with automatic choice
    /// on, else the one chosen by hand. A deleted profile picks nothing.
    public func selected(_ kind: NetworkKind?) -> Profile? {
        let id=(automatic ? kind.flatMap { rules[$0] } : nil) ?? active
        return entries.first { $0.id == id }
    }
    @discardableResult
    public mutating func create(name: String,overrides: VideoOverrides) throws -> Int {
        let name=try check(name,except:nil)
        guard entries.count < Self.maxProfiles else { throw Failure("You can save up to 50 profiles.") }
        let id=(entries.map(\.id).max() ?? 0)+1
        entries.append(Profile(id:id,name:name,overrides:overrides))
        return id
    }
    public mutating func update(id: Int,name: String,overrides: VideoOverrides) throws {
        let name=try check(name,except:id)
        guard let index=entries.firstIndex(where: { $0.id == id }) else { throw Failure("The profile no longer exists.") }
        entries[index].name=name;entries[index].overrides=overrides
    }
    /// Deleting a profile also clears the choices that named it.
    public mutating func delete(id: Int) {
        entries.removeAll { $0.id == id }
        if active == id { active=nil }
        rules=rules.filter { $0.value != id }
    }
    private func check(_ name: String,except: Int?) throws -> String {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...32).contains(name.count) else { throw Failure("Use a name between 1 and 32 characters.") }
        guard !entries.contains(where: { $0.id != except && $0.name.lowercased() == name.lowercased() }) else {
            throw Failure("A profile already uses that name.")
        }
        return name
    }
    private enum CodingKeys: String, CodingKey { case entries,active,automatic,rules }
    public init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        entries=Array(try c.decodeIfPresent([Profile].self,forKey:.entries)?.prefix(Self.maxProfiles) ?? [])
        active=try c.decodeIfPresent(Int.self,forKey:.active)
        automatic=try c.decodeIfPresent(Bool.self,forKey:.automatic) ?? false
        let named=try c.decodeIfPresent([String:Int].self,forKey:.rules) ?? [:]
        rules=Dictionary(uniqueKeysWithValues:named.compactMap { key,id in NetworkKind(rawValue:key).map { ($0,id) } })
    }
    public func encode(to encoder: any Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(entries,forKey:.entries);try c.encodeIfPresent(active,forKey:.active);try c.encode(automatic,forKey:.automatic)
        try c.encode(Dictionary(uniqueKeysWithValues:rules.map { ($0.key.rawValue,$0.value) }),forKey:.rules)
    }
}

/// The games that quit on the PC when their stream is left, as Nightjar keeps them per PC
/// (`HostRecord::quit_on_leave`): only a leave the player chose quits, never a lost connection.
public struct QuitOnLeave: Codable, Equatable, Sendable {
    public static let capacity=256
    private var games: Set<String>=[]
    public init() {}
    private static func key(host: String,game: String) -> String { host+"\n"+game }
    public func quits(host: String,game: String) -> Bool { games.contains(Self.key(host:host,game:game)) }
    public mutating func set(_ enabled: Bool,host: String,game: String) {
        let key=Self.key(host:host,game:game)
        if enabled { if games.count < Self.capacity { games.insert(key) } } else { games.remove(key) }
    }
}
