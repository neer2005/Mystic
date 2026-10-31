import SwiftUI
import MysticCore

struct HomeLibraryContent: View {
    @Bindable var model: ConnectionModel
    @FocusState private var searchFocused: Bool
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
            Picker("Collection",selection:$shelf) {
                Text("All Games").tag("all");Text("Favourites").tag("favourites");Text("Recently Played").tag("recent")
            }.pickerStyle(.segmented).padding(12)
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if filtered.isEmpty {
                        ContentUnavailableView(model.home.games.isEmpty ? "Your Games, Together" : "No Matching Games",systemImage:"gamecontroller",
                            description:Text(model.home.games.isEmpty ? "Pair a PC in the sidebar, then refresh Home. Cached games stay available when a PC is offline." : "Try another search, store or collection."))
                    } else {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:16)],spacing:20) {
                            ForEach(filtered) { game in
                                Button { model.selectedHomeGameID=game.id } label: {
                                    VStack(alignment:.leading,spacing:6) {
                                        if let copy=game.copies.first {
                                            GameArtwork(data:model.home.image(copy),desktop:game.title == "Desktop")
                                                .aspectRatio(2/3,contentMode:.fit)
                                                .task(id:model.home.artKey(copy)+"-"+(model.home.reach[copy.hostID]?.rawValue ?? "unknown")) { await model.loadHomeArt(copy) }
                                        }
                                        HStack { Text(game.title).lineLimit(2);if game.favourite { Image(systemName:"star.fill").foregroundStyle(.yellow) } }.font(.callout)
                                        Text(Array(Set(game.copies.compactMap(\.store))).sorted().joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(game.copies.compactMap { model.home.pc($0.hostID)?.name }.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text(game.copies.contains { model.home.reach[$0.hostID] == .online } ? "Online" : "Cached").font(.caption).foregroundStyle(.secondary)
                                    }.padding(8)
                                        .background(model.selectedHomeGameID == game.id ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:10))
                                        .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(model.selectedHomeGameID == game.id ? Color.accentColor : Color.clear,lineWidth:2) }
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(game.title)
                                    .accessibilityAddTraits(model.selectedHomeGameID == game.id ? .isSelected : [])
                                    .contextMenu { Button(game.favourite ? "Remove Favourite" : "Add Favourite",systemImage:game.favourite ? "star.slash" : "star") { model.home.toggleFavourite(game.id) } }
                            }
                        }
                    }
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
                                Button("Wake \(saved.name)",systemImage:"power") { Task { await model.wakeHomePC(key) } }
                                    .disabled(pc.wake.macs.isEmpty || model.homeBusy || model.isBusy || model.hasSession)
                            } else { Text("Connect and pair to save this PC's library and wake addresses.").font(.caption).foregroundStyle(.secondary) }
                            if let notice=model.home.notices[key] { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                    Text("Wake-on-LAN needs a supported PC and a network path for magic packets; VPN connections may not carry broadcasts.").font(.caption).foregroundStyle(.secondary)
                    if let error=model.home.error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(16)
            }
            Divider()
            HStack {
                if model.homeBusy { ProgressView().controlSize(.small) }
                Text(model.homeMessage).lineLimit(2)
                Spacer();Text("\(filtered.count) \(filtered.count == 1 ? "game" : "games")")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .searchable(text:$query,prompt:"Search games, stores or PCs")
        .searchFocused($searchFocused)
        .focusedSceneValue(\.librarySearchAction, { searchFocused=true })
        .onChange(of:filtered.map(\.id)) {
            if let id=model.selectedHomeGameID,!filtered.contains(where: { $0.id == id }) { model.selectedHomeGameID=filtered.first?.id }
        }
        .toolbar {
            ToolbarItem { Button("Refresh Home",systemImage:"arrow.clockwise") { Task { await model.refreshHome() } }.disabled(model.homeBusy || model.isBusy || model.hasSession) }
            ToolbarItem {
                Menu("Store",systemImage:"line.3.horizontal.decrease") {
                    Picker("Store",selection:$store) {
                        Text("All Stores").tag("all")
                        ForEach(Array(Set(model.home.games.flatMap { $0.copies.compactMap(\.store) })).sorted(),id:\.self) { Text($0).tag($0) }
                    }
                }
            }
        }
        .task { await model.refreshHome() }
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
                    if let copy=game.copies.first { GameArtwork(data:model.home.image(copy),desktop:game.title == "Desktop").frame(height:180) }
                    Text(game.title).font(.title2)
                    Button(game.favourite ? "Remove Favourite" : "Add Favourite",systemImage:game.favourite ? "star.fill" : "star") { model.home.toggleFavourite(game.id) }
                    if let date=game.lastPlayed { LabeledContent("Last played",value:date.formatted(date:.abbreviated,time:.shortened)) }
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
                                Button("Wake \(pc.name)",systemImage:"power") { Task { await model.wakeHomePC(pc.id) } }.disabled(pc.wake.macs.isEmpty || model.homeBusy || model.isBusy || model.hasSession)
                            }
                            Text("Connects to this PC, verifies the current library and uses this game's saved settings. Any required game switch is confirmed before quitting.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section { ContentUnavailableView("Choose a Game",systemImage:"gamecontroller",description:Text("Select a game from Home to choose a PC and see its details.")) }
            }
        }.formStyle(.grouped)
    }
}
