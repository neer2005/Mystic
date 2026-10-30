import Foundation
import MysticCore

extension ConnectionModel {
    /// Host IDs survive address/name changes. Endpoint fallback is only used when the host has no ID.
    public var hostProfileKey: String? {
        guard let host,host.paired else { return nil }
        if !host.uniqueID.isEmpty { return "id:"+Self.profileIdentifier(host.uniqueID) }
        return selectedHostEndpointID.map { "endpoint:"+$0 }
    }
    public var gameProfileKey: String? {
        guard let app=selectedApp else { return nil }
        return app.uuid.isEmpty ? "app-id:\(app.id)" : "uuid:"+Self.profileIdentifier(app.uuid)
    }
    private static func profileIdentifier(_ value: String) -> String {
        UUID(uuidString:value)?.uuidString.lowercased() ?? value
    }
    public var gameVideoSource: GameVideoSource {
        get {
            guard let host=hostProfileKey,let game=gameProfileKey else { return .host }
            return profiles.value.source(host:host,game:game)
        }
        set {
            guard !hasSession,!isBusy,let host=hostProfileKey,let game=gameProfileKey else { return }
            let current=effectiveVideoSettings
            profiles.update { try $0.setGame(source:newValue,video:newValue == .custom ? current : nil,host:host,game:game) }
        }
    }
    public var effectiveVideoSettings: StreamVideoSettings {
        profiles.value.video(defaults:settings.value.videoSettings,host:hostProfileKey,game:gameProfileKey)
    }
    public func updateGameVideo(_ video: StreamVideoSettings) {
        guard !hasSession,!isBusy,gameVideoSource == .custom,let host=hostProfileKey,let game=gameProfileKey else { return }
        profiles.update { try $0.setGame(source:.custom,video:video,host:host,game:game) }
    }
    public func updateHostVideo(_ video: StreamVideoSettings?,hostKey: String) {
        guard !hasSession,!isBusy,hostKey == hostProfileKey else { return }
        profiles.update { try $0.setHost(video,host:hostKey) }
    }
}
