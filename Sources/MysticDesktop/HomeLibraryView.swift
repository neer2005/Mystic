import SwiftUI
import MysticCore

struct HomeLibraryContent: View {
    @Bindable var model: ConnectionModel
    @State private var searchFocus=0
    @Environment(\.openWindow) private var openWindow
    @State private var query=""
    @State private var shelf="all"
    @State private var store="all"
    private var savedPCs: [SavedHost] {
        var seen=Set<String>()
        return model.savedHosts.hosts.filter { seen.insert(HomePC.key(uniqueID:$0.uniqueID,endpoint:$0.endpoint)).inserted }
    }
    private var filtered: [HomeGame] {
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        var games=model.home.games.filter { game in
            (shelf != "favourites" || game.favourite) && (shelf != "recent" || game.lastPlayed != nil)
            && (store == "all" || game.copies.contains { $0.store == store })
            && (query.isEmpty || game.title.localizedStandardContains(query) || game.copies.contains {
                ($0.store?.localizedStandardContains(query) ?? false) || (model.home.pc($0.hostID)?.name.localizedStandardContains(query) ?? false)
            })
        }
        if shelf == "recent" { games.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) } }
        return games
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                LibrarySearchField(text:$query,prompt:"Search Home",focus:searchFocus).frame(maxWidth:320)
                Spacer()
                homeActions
            }.padding(.horizontal,12).padding(.top,12)
            Picker("Collection",selection:$shelf) {
                Text("All Games").tag("all");Text("Favorites").tag("favourites");Text("Recently Played").tag("recent")
            }.pickerStyle(.segmented).padding(12)
            if filtered.isEmpty {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        ContentUnavailableView(model.home.games.isEmpty ? "Your Games, Together" : "No Matching Games",systemImage:"gamecontroller",
                            description:Text(model.home.games.isEmpty ? "Add a PC in the sidebar and its games appear here, even when it's offline." : "Try another search, store or collection."))
                        yourPCs
                    }.padding(16)
                }
            } else {
                GameGrid(items:filtered,selection:Bindable(model).selectedHomeGameID,minimumWidth:150,label:"Games",
                         open:{ game in if let play=playAction(game) { play() } },describe:describe) { game in
                    VStack(alignment:.leading,spacing:6) {
                        if let copy=game.copies.first {
                            GameArtwork(data:model.home.image(copy),desktop:game.title == "Desktop")
                                .aspectRatio(GameArtwork.aspect,contentMode:.fit)
                                .task(id:model.home.artKey(copy)+"-"+(model.home.reach[copy.hostID]?.rawValue ?? "unknown")) { await model.homeSync.loadArt(copy) }
                        }
                        HStack(alignment:.top) { Text(game.title).lineLimit(2,reservesSpace:true);if game.favourite { Image(systemName:"star.fill").foregroundStyle(.yellow) } }.font(.callout)
                        Text(stores(game).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        // The PC only matters with several; offline is the exception worth a line.
                        if savedPCs.count > 1 { Text(pcNames(game).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if availability(game) != "Online" { Label("Offline",systemImage:"moon.zzz").font(.caption).foregroundStyle(.secondary) }
                    }
                } menu: { game in gameMenu(game) } footer: { yourPCs }
            }
            Divider()
            HStack {
                if model.homeSync.busy { ProgressView().controlSize(.small) }
                Text(model.homeSync.message).lineLimit(2)
                Spacer();Text("\(filtered.count) \(filtered.count == 1 ? "game" : "games")")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .focusedSceneValue(\.librarySearchAction, { searchFocus+=1 })
        .onChange(of:filtered.map(\.id)) {
            if let id=model.selectedHomeGameID,!filtered.contains(where: { $0.id == id }) { model.selectedHomeGameID=filtered.first?.id }
        }
        .task { await model.homeSync.refresh() }
    }
    @ViewBuilder private var yourPCs: some View {
        Divider()
        Text("Your PCs").font(.headline)
        ForEach(savedPCs) { saved in
            let key=HomePC.key(uniqueID:saved.uniqueID,endpoint:saved.endpoint)
            VStack(alignment:.leading,spacing:4) {
                HStack {
                    Label(saved.name,systemImage:"desktopcomputer")
                    Spacer()
                    Text(model.home.reach[key]?.rawValue ?? "Not checked").foregroundStyle(.secondary)
                }
                if let pc=model.home.pc(key) {
                    Text("Library saved \(pc.updated.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                    Button("Wake \(saved.name)",systemImage:"power") { Task { await model.homeSync.wake(key) } }
                        .disabled(pc.wake.macs.isEmpty || model.homeSync.busy || model.isBusy || model.hasSession)
                } else { Text("Connect and pair to save this PC's library and wake addresses.").font(.caption).foregroundStyle(.secondary) }
                if let notice=model.home.notices[key] { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        Text("Waking a PC needs it to support Wake-on-LAN, and may not work over a VPN.").font(.caption).foregroundStyle(.secondary)
        if let error=model.home.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    private func stores(_ game: HomeGame) -> [String] { Array(Set(game.copies.compactMap(\.store))).sorted() }
    private func pcNames(_ game: HomeGame) -> [String] { game.copies.compactMap { model.home.pc($0.hostID)?.name } }
    private func availability(_ game: HomeGame) -> String { game.copies.contains { model.home.reach[$0.hostID] == .online } ? "Online" : "Cached" }
    /// Playing from the grid needs a single PC; a game on several PCs is played from its details.
    private func playAction(_ game: HomeGame) -> (() -> Void)? {
        guard game.copies.count == 1,let copy=game.copies.first,model.home.pc(copy.hostID) != nil,!model.isBusy,!model.hasSession else { return nil }
        return { Task { await model.openHomeGame(copy);if model.hasSession { openWindow(id:"stream") } } }
    }
    private func describe(_ game: HomeGame) -> GameCardDescription {
        var value: [String]=game.favourite ? ["Favorite"] : []
        value+=stores(game)
        let pcs=pcNames(game)
        if !pcs.isEmpty { value.append("on "+pcs.joined(separator:" and ")) }
        value.append(availability(game))
        var description=GameCardDescription(label:game.title,value:value.joined(separator:", "))
        if let play=playAction(game),let pc=pcs.first { description.actions.append(("Play on \(pc)",play)) }
        description.actions.append((game.favourite ? "Remove from Favorites" : "Add to Favorites",{ model.home.toggleFavourite(game.id) }))
        return description
    }
    /// Mirrors the card's accessibility actions, so VoiceOver's menu command reaches them too.
    @ViewBuilder private func gameMenu(_ game: HomeGame) -> some View {
        if let play=playAction(game),let pc=pcNames(game).first { Button("Play on \(pc)",systemImage:"play.fill",action:play) }
        Button(game.favourite ? "Remove from Favorites" : "Add to Favorites",systemImage:game.favourite ? "star.slash" : "star") { model.home.toggleFavourite(game.id) }
    }
    private var homeActions: some View {
        HStack(spacing:8) {
            Button("Refresh Home",systemImage:"arrow.clockwise") { Task { await model.homeSync.refresh() } }
                .disabled(model.homeSync.busy || model.isBusy || model.hasSession)
                .help("Refresh paired PC libraries")
            Menu("Store",systemImage:"line.3.horizontal.decrease") {
                Picker("Store",selection:$store) {
                    Text("All Stores").tag("all")
                    ForEach(Array(Set(model.home.games.flatMap { $0.copies.compactMap(\.store) })).sorted(),id:\.self) { Text($0).tag($0) }
                }
            }.help("Filter games by store")
        }.labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
    }

}

struct HomeGameDetails: View {
    @Bindable var model: ConnectionModel
    @Environment(\.openWindow) private var openWindow
    private var selected: HomeGame? { model.home.games.first { $0.id == model.selectedHomeGameID } }
    var body: some View {
        Form {
            if let game=selected {
                Section {
                    HStack(alignment:.top,spacing:12) {
                        GameArtwork(data:game.copies.first.flatMap(model.home.image),desktop:game.title == "Desktop").frame(width:72,height:108)
                        VStack(alignment:.leading,spacing:4) {
                            Text(game.title).font(.title3.weight(.semibold)).lineLimit(3)
                            if let date=game.lastPlayed { Text("Last played \(date.formatted(date:.abbreviated,time:.shortened))").foregroundStyle(.secondary) }
                        }
                    }
                    Button(game.favourite ? "Remove from Favorites" : "Add to Favorites",systemImage:game.favourite ? "star.fill" : "star") { model.home.toggleFavourite(game.id) }
                }
                ForEach(game.copies) { copy in
                    if let pc=model.home.pc(copy.hostID) {
                        Section(pc.name) {
                            if let store=copy.store { LabeledContent("Store",value:store) }
                            LabeledContent("Status",value:model.home.reach[pc.id]?.rawValue ?? "Not checked")
                            Text("Library saved \(pc.updated.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                            Button("Play on \(pc.name)",systemImage:"play.fill") {
                                Task { await model.openHomeGame(copy);if model.hasSession { openWindow(id:"stream") } }
                            }.buttonStyle(.borderedProminent).disabled(model.isBusy || model.hasSession)
                            if model.home.reach[pc.id] != .online {
                                Button("Wake \(pc.name)",systemImage:"power") { Task { await model.homeSync.wake(pc.id) } }.disabled(pc.wake.macs.isEmpty || model.homeSync.busy || model.isBusy || model.hasSession)
                            }
                            Text("Uses this game's saved settings. If another game is running, you'll be asked before it quits.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section { ContentUnavailableView("Choose a Game",systemImage:"gamecontroller",description:Text("Select a game from Home to choose a PC and see its details.")) }
            }
        }.formStyle(.grouped)
    }
}
