import SwiftUI
import MysticCore

/// Settings → Network → Network Profiles: named changes to the stream settings, chosen by hand
/// or by the kind of network toward the PC.
struct NetworkProfilesView: View {
    @Bindable var model: ConnectionModel
    @State private var editing: ProfileDraft?
    private var document: PreferenceDocument<NetworkProfiles> { model.networkProfiles }
    private var profiles: NetworkProfiles { document.value }
    private var choices: some View {
        Group {
            Text("None").tag(Int?.none)
            ForEach(profiles.entries) { Text($0.name).tag(Optional($0.id)) }
        }
    }
    var body: some View {
        Group { content }.sheet(item:$editing) { draft in NetworkProfileEditor(draft:draft,document:document) }
    }
    @ViewBuilder private var content: some View {
        ForEach(profiles.entries) { profile in
            HStack {
                VStack(alignment:.leading) {
                    Text(profile.name)
                    Text(profile.overrides.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { editing=ProfileDraft(profile) }
                Button("Delete",role:.destructive) { document.update { $0.delete(id:profile.id) } }
            }
        }
        Button("Add Profile…") { editing=ProfileDraft() }.disabled(profiles.entries.count >= NetworkProfiles.maxProfiles)
        Picker("Use",selection:Binding(get:{ profiles.active },set:{ id in document.update { $0.active=id } })) { choices }
        Toggle("Choose by Network",isOn:Binding(get:{ profiles.automatic },set:{ on in document.update { $0.automatic=on } }))
        if profiles.automatic {
            ForEach(NetworkKind.allCases,id:\.self) { kind in
                Picker(kind.label,selection:Binding(get:{ profiles.rules[kind] },set:{ id in document.update { $0.rules[kind]=id } })) { choices }
            }
        }
        if let kind=model.networkKind {
            Text("Toward the connected PC: \(kind.label)\(model.activeNetworkProfile.map { ", using \($0.name)" } ?? "").")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("A profile changes only the settings it names, on top of the global, host and game settings, for streams started afterwards. Without a rule for the network, Use applies. Home and away are told apart by the route to the PC: a VPN or an address outside the local network is away.")
            .font(.caption).foregroundStyle(.secondary)
        if let error=document.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

struct ProfileDraft: Identifiable {
    var id: Int?
    var name=""
    var overrides=VideoOverrides()
    init() {}
    init(_ profile: NetworkProfiles.Profile) { id=profile.id;name=profile.name;overrides=profile.overrides }
}

private struct NetworkProfileEditor: View {
    @State var draft: ProfileDraft
    let document: PreferenceDocument<NetworkProfiles>
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    /// A switch for whether the profile sets a value, and the value while it does.
    private func optional<T>(_ key: WritableKeyPath<VideoOverrides,T?>,_ fallback: T) -> (Binding<Bool>,Binding<T>) {
        (Binding(get:{ draft.overrides[keyPath:key] != nil },set:{ draft.overrides[keyPath:key]=$0 ? fallback : nil }),
         Binding(get:{ draft.overrides[keyPath:key] ?? fallback },set:{ draft.overrides[keyPath:key]=$0 }))
    }
    var body: some View {
        let resolution=optional(\.resolution,"1920x1080"),fps=optional(\.fps,UInt32(60)),bitrate=optional(\.bitrateMbps,Int32(15))
        let hdr=optional(\.hdr,false),adaptive=optional(\.adaptiveBitrate,true),quality=optional(\.automaticQuality,AutomaticQuality.motion)
        Form {
            TextField("Name",text:$draft.name,prompt:Text("Travel"))
            Section("Changes") {
                Toggle("Resolution",isOn:resolution.0)
                if resolution.0.wrappedValue {
                    Picker("Resolution",selection:resolution.1) { ForEach(StreamPreferences.resolutions,id:\.self) { Text(StreamPreferences.resolutionLabel($0)).tag($0) } }
                }
                Toggle("Frame Rate",isOn:fps.0)
                if fps.0.wrappedValue { Picker("Frame Rate",selection:fps.1) { Text("60 fps").tag(UInt32(60));Text("120 fps").tag(UInt32(120)) } }
                Toggle("Bitrate",isOn:bitrate.0)
                if bitrate.0.wrappedValue {
                    Stepper("\(bitrate.1.wrappedValue) Mbps",value:bitrate.1,in:5...150,step:5)
                }
                Toggle("Automatic Bitrate",isOn:adaptive.0)
                if adaptive.0.wrappedValue { Toggle("On",isOn:adaptive.1) }
                Toggle("Automatic Quality",isOn:quality.0)
                if quality.0.wrappedValue {
                    Picker("Favor",selection:quality.1) { ForEach(AutomaticQuality.allCases,id:\.self) { Text($0.label).tag($0) } }
                }
                Toggle("HDR",isOn:hdr.0)
                if hdr.0.wrappedValue { Toggle("On",isOn:hdr.1) }
            }
            Text(draft.overrides.summary).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped).frame(width:420,height:480)
        .toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement:.confirmationAction) {
                Button("Save") {
                    let saved=document.update { profiles in
                        if let id=draft.id { try profiles.update(id:id,name:draft.name,overrides:draft.overrides) }
                        else { try profiles.create(name:draft.name,overrides:draft.overrides) }
                    }
                    if saved { dismiss() } else { error=document.error }
                }
            }
        }
    }
}
