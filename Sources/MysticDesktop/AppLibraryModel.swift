import Foundation
import Observation
import MysticKit
import MysticCore

/// The connected host's apps: native library metadata, artwork, search, filter and selection.
@MainActor @Observable
public final class AppLibraryModel {
    public private(set) var apps: [HostApp]=[]
    public private(set) var native: HostLibrary?
    public private(set) var notice: String?
    /// Changes whenever the app list or its artwork is replaced, so artwork tasks restart.
    public private(set) var artworkID=UUID()
    public private(set) var artwork: [Int32: Data]=[:]
    public var selectedID: Int32?
    public var query="" { didSet { reconcileSelection() } }
    public var hdrOnly=false { didSet { reconcileSelection() } }
    @ObservationIgnored private var artworkRequests=Set<Int32>()
    @ObservationIgnored private var artworkOrder: [Int32]=[]
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }

    public var selected: HostApp? { apps.first { $0.id == selectedID } }
    public func game(_ app: HostApp) -> HostLibrary.Game? { native?.game(appID:app.id) }
    /// The app the host reports running, when it is in this list.
    public var runningApp: HostApp? {
        guard let id=model.host?.currentGame,id > 0 else { return nil }
        return apps.first { $0.id == id }
    }
    public func isRunning(_ app: HostApp) -> Bool { model.host?.currentGame == app.id || game(app)?.running == true }
    public var selectedRunning: Bool { selected.map(isRunning) ?? false }
    public var filtered: [HostApp] {
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        let filtered=apps.filter { (!hdrOnly || $0.hdrSupported) && (query.isEmpty || ($0.name.localizedStandardContains(query) || (game($0)?.store?.name.localizedStandardContains(query) ?? false))) }
        return model.settings.value.librarySort == "host" ? filtered : filtered.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func reconcileSelection() {
        if let selectedID,!filtered.contains(where: { $0.id == selectedID }) { self.selectedID=filtered.first?.id }
    }
    func clear() {
        clearArtwork();native=nil;notice=nil
        apps=[];selectedID=nil
    }
    private func clearArtwork() { artworkRequests=[];artworkOrder=[];artwork=[:] }
    /// Starts a reload: artwork tasks for the old list stop applying their results.
    func beginReload() { artworkID=UUID() }
    /// `previous` is the selection when the reload began; it is kept if still listed.
    func replace(apps list: [HostApp],library: HostLibrary?,notice: String?,keeping previous: Int32?) {
        artworkID=UUID();native=library;self.notice=notice;clearArtwork()
        apps=library?.merging(apps:list) ?? list
        selectedID=filtered.contains(where: { $0.id == previous }) ? previous : filtered.first?.id
    }
    public func loadArtwork(_ id: Int32) async {
        guard model.phase == .ready,let connection=model.connection,artwork[id] == nil,artworkRequests.insert(id).inserted else { return }
        let token=model.generation,artToken=artworkID
        let bytes=try? await connection.artwork(appID:id)
        guard model.generation == token,artworkID == artToken else { return }
        if let bytes {
            artwork[id]=bytes;artworkOrder.append(id)
            if let copy=model.connectedHomePC?.games.first(where: { $0.app.id == id }) { model.home.saveArt(bytes,for:copy) }
            if artworkOrder.count > 64 {
                let evicted=artworkOrder.removeFirst()
                artwork.removeValue(forKey:evicted);artworkRequests.remove(evicted)
            }
        }
    }
}
