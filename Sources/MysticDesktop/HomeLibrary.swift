import Foundation
import Observation
import CryptoKit
import MysticCore
import MysticKit

public struct HomeInstallation: Codable, Sendable, Identifiable {
    public let hostID: String
    public let app: HostApp
    public let gameID: String?
    public let store: String?
    public let coverVersion: String
    public var id: String { hostID+"|"+(app.uuid.isEmpty ? "app:\(app.id)" : "uuid:"+(UUID(uuidString:app.uuid)?.uuidString.lowercased() ?? app.uuid)) }
    public var groupID: String { gameID.flatMap { $0.isEmpty ? nil : "game:"+$0 } ?? id }
}
public struct HomePC: Codable, Sendable, Identifiable {
    public let id: String
    public let uniqueID: String
    public var name: String
    public var endpoint: HostEndpoint
    public var updated: Date
    public var games: [HomeInstallation]
    public var wake: HostWakeTargets
    public static func key(uniqueID: String?,endpoint: HostEndpoint) -> String {
        uniqueID.flatMap { $0.isEmpty ? nil : "host:"+$0 } ?? "endpoint:"+endpoint.id
    }
}
public struct HomeGame: Identifiable {
    public let id: String
    public let title: String
    public let copies: [HomeInstallation]
    public let favourite: Bool
    public let lastPlayed: Date?
}

@MainActor @Observable
public final class HomeLibrary {
    public enum Reachability: String { case unknown="Not checked", checking="Checking…", online="Online", offline="Unreachable", pairing="Pairing required" }
    private struct Document: Codable {
        var version=1
        var pcs: [HomePC]=[]
        var favourites: Set<String>=[]
        var recent: [String:Date]=[:]
    }
    @ObservationIgnored private var document=Document()
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let artRoot: URL?
    public private(set) var pcs: [HomePC]=[]
    public private(set) var reach: [String:Reachability]=[:]
    public private(set) var notices: [String:String]=[:]
    public private(set) var images: [String:Data]=[:]
    public private(set) var error: String?
    public private(set) var revision=UUID()
    @ObservationIgnored private var imageOrder: [String]=[]
    public init(defaults: UserDefaults? = nil,artRoot: URL? = nil) {
        self.defaults=defaults;self.artRoot=artRoot
        if let data=defaults?.data(forKey:"homeLibrary.v1") {
            do {
                guard data.count <= 8*1024*1024 else { throw CocoaError(.fileReadTooLarge) }
                let value=try JSONDecoder().decode(Document.self,from:data)
                guard value.version == 1,value.pcs.count <= 32,value.pcs.reduce(0,{$0+$1.games.count}) <= 5000,
                    value.favourites.count <= 5000,value.recent.count <= 5000,
                    Set(value.pcs.map(\.id)).count == value.pcs.count,
                    value.pcs.allSatisfy({ pc in pc.id == HomePC.key(uniqueID:pc.uniqueID,endpoint:pc.endpoint) && pc.games.count <= 1000 && pc.wake.macs.count <= 8 && pc.wake.broadcasts.count <= 16 && pc.games.allSatisfy { $0.hostID == pc.id && $0.app.id > 0 } }) else { throw CocoaError(.fileReadCorruptFile) }
                document=value;pcs=value.pcs
            } catch { self.error="Cached Home library could not be read. Refresh your paired PCs to rebuild it." }
        }
    }
    public var games: [HomeGame] {
        // Observation must read a tracked value before the private metadata document.
        let _=revision
        let grouped=Dictionary(grouping:pcs.flatMap(\.games),by:\.groupID)
        return grouped.map { id,copies in
            let copies=copies.sorted { a,b in
                let ao=reach[a.hostID] == .online,bo=reach[b.hostID] == .online
                return ao == bo ? a.id < b.id : ao
            }
            return HomeGame(id:id,title:copies[0].app.name,copies:copies,favourite:document.favourites.contains(id),lastPlayed:copies.compactMap { document.recent[$0.id] }.max())
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func pc(_ id: String) -> HomePC? { pcs.first { $0.id == id } }
    public func setReach(_ id: String,_ state: Reachability,notice: String? = nil) { reach[id]=state;notices[id]=notice }
    public func reconcile(_ hosts: [SavedHost]) {
        var byKey: [String:SavedHost]=[:]
        for host in hosts { let key=HomePC.key(uniqueID:host.uniqueID,endpoint:host.endpoint);if byKey[key] == nil { byKey[key]=host } }
        pcs=pcs.compactMap { pc in
            guard let host=byKey[pc.id] else { return nil }
            var pc=pc;pc.endpoint=host.endpoint;pc.name=host.name;return pc
        }
        let keep=Set(pcs.map(\.id))
        reach=reach.filter { keep.contains($0.key) };notices=notices.filter { keep.contains($0.key) }
        pruneMetadata();persist()
    }
    public func record(host: HostInfo,endpoint: HostEndpoint,apps: [HostApp],library: HostLibrary?,wake: HostWakeTargets? = nil) {
        let key=HomePC.key(uniqueID:host.uniqueID,endpoint:endpoint)
        let old=pc(key)
        let favouriteCopies=Set(pcs.flatMap(\.games).filter { document.favourites.contains($0.groupID) }.map(\.id))
        let remaining=max(0,5000-pcs.filter { $0.id != key && $0.endpoint != endpoint }.reduce(0,{$0+$1.games.count}))
        var seen=Set<Int32>()
        let games=apps.filter { $0.id > 0 && seen.insert($0.id).inserted }.prefix(min(1000,remaining)).map { app in
            let game=library?.game(appID:app.id)
            return HomeInstallation(hostID:key,app:app,gameID:game?.game_id,store:game?.store?.name,coverVersion:game?.artwork.version ?? "classic-\(Int(Date().timeIntervalSince1970/86400))")
        }
        pcs.removeAll { $0.id == key || $0.endpoint == endpoint }
        pcs.append(HomePC(id:key,uniqueID:host.uniqueID,name:host.name,endpoint:endpoint,updated:Date(),games:games,wake:wake ?? old?.wake ?? HostWakeTargets()))
        for copy in games where favouriteCopies.contains(copy.id) { document.favourites.insert(copy.groupID) }
        pcs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if pcs.count > 32 { pcs.removeLast(pcs.count-32) }
        setReach(key,.online);pruneMetadata();persist()
    }
    public func toggleFavourite(_ id: String) {
        if document.favourites.contains(id) { document.favourites.remove(id) } else if document.favourites.count < 5000 { document.favourites.insert(id) }
        persist()
    }
    public func played(hostID: String,app: HostApp,at date: Date = Date()) {
        guard let copy=pc(hostID)?.games.first(where: { $0.app.id == app.id }) else { return }
        document.recent[copy.id]=date;persist()
    }
    private func pruneMetadata() {
        let copies=pcs.flatMap(\.games),ids=Set(copies.map(\.id)),groups=Set(copies.map(\.groupID))
        document.recent=document.recent.filter { ids.contains($0.key) };document.favourites.formIntersection(groups)
        let artKeys=Set(copies.map(artKey));images=images.filter { artKeys.contains($0.key) };imageOrder.removeAll { !artKeys.contains($0) }
    }
    private func persist() {
        revision=UUID();document.pcs=pcs
        do {
            let data=try JSONEncoder().encode(document)
            guard data.count <= 8*1024*1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            defaults?.set(data,forKey:"homeLibrary.v1");error=nil
        } catch { self.error="Home library changes could not be saved." }
    }
    public func artKey(_ copy: HomeInstallation) -> String {
        SHA256.hash(data:Data((copy.id+"|"+copy.coverVersion).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    public func cachedArt(_ copy: HomeInstallation) -> Data? {
        let key=artKey(copy)
        if let data=images[key] { return data }
        guard let root=artRoot else { return nil }
        let file=root.appendingPathComponent(key)
        guard let size=(try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size <= 4*1024*1024,
            let data=try? Data(contentsOf:file),data.count <= 4*1024*1024 else { return nil }
        rememberImage(data,key:key);return data
    }
    public func saveArt(_ data: Data,for copy: HomeInstallation) {
        guard data.count <= 4*1024*1024,pc(copy.hostID)?.games.contains(where: { $0.id == copy.id && $0.coverVersion == copy.coverVersion }) == true else { return }
        let key=artKey(copy);rememberImage(data,key:key)
        guard let root=artRoot else { return }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try data.write(to:root.appendingPathComponent(key),options:.atomic)
            // Keep at most 64 MiB of encoded covers on disk, oldest files first.
            let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]).filter { $0.lastPathComponent.count == 64 }
            let info=files.compactMap { url -> (URL,Int,Date)? in
                guard let v=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { return nil }
                return (url,v.fileSize ?? 0,v.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var total=info.reduce(0,{$0+$1.1})
            for file in info where total > 64*1024*1024 { try? FileManager.default.removeItem(at:file.0);total-=file.1 }
        } catch { /* Cover caches are disposable; metadata and streaming remain usable. */ }
    }
    public func image(_ copy: HomeInstallation) -> Data? { images[artKey(copy)] }
    private func rememberImage(_ data: Data,key: String) {
        images[key]=data;imageOrder.removeAll { $0 == key };imageOrder.append(key)
        while imageOrder.count > 32 { images.removeValue(forKey:imageOrder.removeFirst()) }
    }
}
