import Foundation

public enum GraphicsValue: Codable, Sendable, Hashable {
    case toggle(Bool), integer(Int64), choice(String)
    public init(from decoder: any Decoder) throws {
        let c=try decoder.singleValueContainer()
        if let v=try? c.decode(Bool.self) { self = .toggle(v) }
        else if let v=try? c.decode(Int64.self) { self = .integer(v) }
        else { self = .choice(try c.decode(String.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self { case .toggle(let v):try c.encode(v);case .integer(let v):try c.encode(v);case .choice(let v):try c.encode(v) }
    }
    public var text: String {
        switch self { case .toggle(let v):v ? "On" : "Off";case .integer(let v):String(v);case .choice(let v):v }
    }
}

public struct HostGraphics: Decodable, Sendable {
    public let revision: UInt64
    public let state: String
    public let host_control: Bool
    public let writable_now: Bool
    public let message: String?
    public let reason: String?
    public let gpus: [GPU]
    public var writable: Bool { state == "configurable" && host_control && writable_now }
    public var notice: String? {
        if let message,!message.isEmpty { return message }
        switch state {
        case "configurable": return !host_control ? "Allow Host control for this device on the host to change graphics settings." : (!writable_now ? "Graphics changes require a session owned by this device." : nil)
        case "read_only": return "These settings can be viewed but not changed."
        case "needs_external_setup": return "Complete setup in AMD Software on the host."
        case "temporarily_unavailable": return reason == "adlx_unavailable" ? "The host could not load the AMD driver interface." : "Graphics settings are temporarily unavailable."
        default: return "Graphics controls are not supported on this GPU or driver."
        }
    }
    public struct GPU: Decodable, Sendable, Identifiable {
        public let id: Int32
        public let name: String
        public let driver: String
        public let settings: [Setting]
    }
    public struct Setting: Decodable, Sendable, Identifiable {
        public let id: String
        public let group: String
        public let kind: String
        public let state: String
        public let value: GraphicsValue?
        public let range: Range?
        public let options: [Choice]?
        public let unit: String?
        public let message: String?
        public let restore: Restore?
        public struct Range: Decodable, Sendable { public let min: Int64; public let max: Int64; public let step: Int64 }
        public struct Choice: Decodable, Sendable, Hashable { public let value: String;public let label: String }
        public struct Restore: Decodable, Sendable { public let original: GraphicsValue;public let written: GraphicsValue }
        public var title: String {
            let parts=id.split(separator:".",maxSplits:1).map(String.init)
            let groups=["anti_lag":"Radeon Anti-Lag","chill":"Radeon Chill","afmf":"AMD Fluid Motion Frames","rsr":"Radeon Super Resolution","image_sharpening":"Radeon Image Sharpening","vsync":"V-Sync","enhanced_sync":"Enhanced Sync","frame_rate_target":"Frame Rate Target"]
            let name=groups[parts.first ?? group] ?? (parts.first ?? group).replacingOccurrences(of:"_",with:" ").capitalized
            guard parts.count > 1,!(["enabled","mode"].contains(parts[1])) else { return name }
            let fields=["min_fps":"Minimum FPS","max_fps":"Maximum FPS","fps":"FPS","sharpness":"Sharpness"]
            return name+": "+(fields[parts[1]] ?? parts[1].replacingOccurrences(of:"_",with:" ").capitalized)
        }
        public var valueText: String {
            guard let value else { return "Unavailable" }
            if case .choice(let key)=value { return options?.first { $0.value == key }?.label ?? key }
            return value.text + (unit.map { " "+$0 } ?? "")
        }
        public func accepts(_ candidate: GraphicsValue) -> Bool {
            guard state == "configurable",value != nil else { return false }
            switch (kind,value,candidate) {
            case ("toggle",.toggle?,.toggle):return true
            case ("choice",.choice?,.choice(let c)):return options?.contains { $0.value == c } == true
            case ("integer",.integer?,.integer(let n)):
                guard let range,range.step > 0,range.max > range.min,n >= range.min,n <= range.max else { return false }
                let (offset,overflow)=n.subtractingReportingOverflow(range.min)
                return !overflow && offset % range.step == 0
            default:return false
            }
        }
        public var editable: Bool { value.map(accepts) ?? false }
        public var note: String? {
            if let message,!message.isEmpty { return message }
            switch state {
            case "configurable":return editable ? nil : "This setting has no supported editable value."
            case "read_only":return "Read only"
            case "needs_external_setup":return "Complete setup in AMD Software on the host."
            case "temporarily_unavailable":return "Temporarily unavailable"
            default:return "Not supported on this GPU or driver"
            }
        }
    }
}
