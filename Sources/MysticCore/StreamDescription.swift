import Foundation

/// A parsed RTSP `DESCRIBE` response describing what a host is willing to stream.
///
/// The client's job during negotiation is to take everything the host offers and
/// nothing it does not. Hosts in this ecosystem (Sunshine, Apollo, Vibepollo,
/// Rubylight) advertise capabilities through standard SDP (`m=`, `a=rtpmap`,
/// `a=fmtp`) plus a family of `x-ss-*` extension attributes, so the parser keeps
/// both: typed payload mappings for the parts every host shares, and a raw
/// attribute map for the vendor extensions.
public struct StreamDescription: Sendable, Equatable {

    /// One `a=rtpmap` entry.
    public struct PayloadMapping: Sendable, Equatable {
        public let payloadType: Int
        public let encoding: String
        public let clockRate: Int
        /// Present only for audio encodings that declare it (`opus/48000/2`).
        public let channelCount: Int?

        public init(payloadType: Int, encoding: String, clockRate: Int, channelCount: Int? = nil) {
            self.payloadType = payloadType
            self.encoding = encoding
            self.clockRate = clockRate
            self.channelCount = channelCount
        }

        /// `fmtp` parameters keyed by name, e.g. `minptime` -> `10`.
        public var formatParameters: [String: String] = [:]
    }

    /// One `m=` section.
    public struct MediaSection: Sendable, Equatable {
        public enum Kind: String, Sendable { case audio, video, application, unknown }

        public let kind: Kind
        public let port: Int
        public let transport: String
        public let formats: [String]
        public var mappings: [PayloadMapping] = []
    }

    public private(set) var sessionName: String?
    public private(set) var sections: [MediaSection] = []
    /// Every `x-ss-*` attribute, keyed by its full name (e.g.
    /// `x-ss-general.encryptionSupported`).
    public private(set) var extensions: [String: String] = [:]

    public init(sessionName: String? = nil, sections: [MediaSection] = [], extensions: [String: String] = [:]) {
        self.sessionName = sessionName
        self.sections = sections
        self.extensions = extensions
    }

    // MARK: - Capability queries

    public var videoSections: [MediaSection] { sections.filter { $0.kind == .video } }
    public var audioSections: [MediaSection] { sections.filter { $0.kind == .audio } }

    /// Encodings the host offers, upper-cased and de-duplicated, e.g.
    /// `["H264", "HEVC", "AV1", "OPUS"]`.
    public var offeredEncodings: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for section in sections {
            for mapping in section.mappings {
                let name = mapping.encoding.uppercased()
                if seen.insert(name).inserted { result.append(name) }
            }
        }
        return result
    }

    /// True when any audio section declares more than one channel, which is how a
    /// host advertises multichannel game audio rather than the mono mic stream.
    public var offersMultichannelAudio: Bool {
        audioSections.contains { section in
            section.mappings.contains { ($0.channelCount ?? 1) > 1 }
        }
    }

    /// True when the host asks for encrypted streams. Hosts in this ecosystem
    /// refuse a microphone stream in the clear, so this gates mic capture.
    public var requiresEncryption: Bool {
        for (key, value) in extensions where key.hasSuffix("encryptionRequested") {
            if value == "1" || value.lowercased() == "true" { return true }
        }
        return false
    }

    /// Value of an `x-ss-*` extension, if present.
    public func extendedValue(_ key: String) -> String? { extensions[key] }

    // MARK: - Parsing

    /// Parses an SDP body. Unknown lines are ignored rather than rejected: hosts
    /// add extensions over time and a strict parser breaks on every host update.
    public static func parse(_ sdp: String) -> StreamDescription {
        var description = StreamDescription()
        var current: MediaSection?

        for rawLine in sdp.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, line[line.index(line.startIndex, offsetBy: 1)] == "=" else { continue }
            let key = line.first!
            let value = String(line.dropFirst(2))

            switch key {
            case "s":
                description.sessionName = value

            case "m":
                if let section = parseMediaLine(value) {
                    if let finished = current { description.sections.append(finished) }
                    current = section
                }

            case "a":
                applyAttribute(value, to: &current, description: &description)

            default:
                continue
            }
        }
        if let finished = current { description.sections.append(finished) }
        return description
    }

    private static func parseMediaLine(_ value: String) -> MediaSection? {
        // m=<media> <port> <proto> <fmt> ...
        let fields = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 3, let port = Int(fields[1]) else { return nil }
        return MediaSection(
            kind: MediaSection.Kind(rawValue: fields[0].lowercased()) ?? .unknown,
            port: port,
            transport: fields[2],
            formats: Array(fields.dropFirst(3))
        )
    }

    private static func applyAttribute(
        _ value: String,
        to current: inout MediaSection?,
        description: inout StreamDescription
    ) {
        // rtpmap:<pt> <encoding>/<clock>[/<channels>]
        if value.hasPrefix("rtpmap:") {
            let body = value.dropFirst("rtpmap:".count)
            let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let payloadType = Int(parts[0]) else { return }
            let encodingParts = parts[1].split(separator: "/")
            guard let encoding = encodingParts.first, let clock = encodingParts.count > 1 ? Int(encodingParts[1]) : nil else { return }
            let channels = encodingParts.count > 2 ? Int(encodingParts[2]) : nil
            current?.mappings.append(
                PayloadMapping(payloadType: payloadType, encoding: String(encoding), clockRate: clock, channelCount: channels)
            )
            return
        }

        // fmtp:<pt> <param>=<value>;<param>=<value>
        if value.hasPrefix("fmtp:") {
            let body = value.dropFirst("fmtp:".count)
            let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let payloadType = Int(parts[0]) else { return }
            var params: [String: String] = [:]
            for pair in parts[1].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    params[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
            if let index = current?.mappings.firstIndex(where: { $0.payloadType == payloadType }) {
                current?.mappings[index].formatParameters = params
            }
            return
        }

        // x-ss-<domain>.<key>:<value>  (Sunshine-family extensions)
        if value.hasPrefix("x-ss-") {
            let kv = value.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                description.extensions[kv[0].trimmingCharacters(in: .whitespaces)] =
                    kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
    }
}
