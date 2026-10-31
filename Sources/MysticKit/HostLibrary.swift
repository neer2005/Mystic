import Foundation

/// Rubylight native API v1. Artwork paths are metadata only; images use pinned box-art requests.
public struct HostLibrary: Decodable, Sendable {
    public let revision: String
    public let games: [Game]
    public struct Game: Decodable, Sendable {
        public let game_id: String?
        public let install_id: String
        public let app_id: Int32
        public let title: String
        public let store: Store?
        public let installed: Bool?
        public let running: Bool
        public let artwork: Artwork
    }
    public struct Store: Decodable, Sendable {
        public let source: String
        public let name: String
    }
    public struct Artwork: Decodable, Sendable {
        public let cover: String?
        public let version: String
    }
    /// Keep classic launch UUIDs and HDR capabilities, including non-library apps such as Desktop.
    public func merging(apps: [HostApp]) -> [HostApp] {
        var result = apps
        var seen = Set<Int32>()
        for game in games where game.app_id > 0 && game.installed != false {
            guard seen.insert(game.app_id).inserted else { continue }
            if let index = result.firstIndex(where: { $0.id == game.app_id }) {
                let app = result[index]
                result[index] = HostApp(id:app.id,name:game.title,uuid:app.uuid,hdrSupported:app.hdrSupported)
            } else {
                result.append(HostApp(id:game.app_id,name:game.title,uuid:"",hdrSupported:false))
            }
        }
        return result
    }
    public func game(appID: Int32) -> Game? {
        games.first { $0.app_id == appID && $0.installed != false }
    }
}
