import Foundation

public enum HostSessionAction: String, CaseIterable, Sendable, Identifiable {
    case disconnect, end, closeGame = "close_game"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .disconnect: "Disconnect Host Session"
        case .end: "End Host Session"
        case .closeGame: "Close Game on Host"
        }
    }
    public var explanation: String {
        switch self {
        case .disconnect: "Disconnect this device's host session. The game stays running."
        case .end: "End this device's session and restore temporary host settings. The game stays running."
        case .closeGame: "Close the running game on the host. Unsaved progress may be lost."
        }
    }
}

public struct HostSession: Decodable, Sendable {
    public let state: String
    public let owner: String
    public let app: App?
    public let game_running: Bool
    public let actions: [Action]
    public struct App: Decodable, Sendable {
        public let app_id: Int32
        public let title: String
    }
    public struct Action: Decodable, Sendable {
        public let id: String
        public let allowed: Bool
        public let reason: String?
    }
    public func allows(_ action: HostSessionAction) -> Bool {
        actions.first { $0.id == action.rawValue }?.allowed == true
    }
    public func blockedReason(_ action: HostSessionAction) -> String? {
        guard !allows(action) else { return nil }
        let reason=actions.first { $0.id == action.rawValue }?.reason
        switch reason {
        case "not_session_owner": return "This session belongs to another device."
        case "host_control_required": return "Allow Host control for this device on the host."
        case "permission_required": return "The host has not granted this device permission."
        case "session_busy", "temporarily_unavailable": return "The host is busy. Try again shortly."
        case "no_session": return "There is no active session."
        case "not_streaming": return "This device is not streaming."
        default: return "Not available on this host right now."
        }
    }
}
