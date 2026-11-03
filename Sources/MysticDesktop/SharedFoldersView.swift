import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MysticKit

/// The folders a PC shares with this Mac: browse them, download a file into a folder chosen here,
/// and upload where the PC grants writing. One transfer at a time; closing cancels it, as on Nightjar.
@MainActor @Observable
final class SharedFoldersModel: Identifiable {
    private(set) var snapshot: FoldersSnapshot?
    private(set) var problem: String?
    private let page: any FoldersPage
    @ObservationIgnored private var poller: Task<Void,Never>?
    init(page: any FoldersPage) { self.page=page }
    func start() {
        guard poller == nil else { return }
        send("snapshot")
        poller=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.milliseconds(100))
                self?.send("snapshot")
            }
        }
    }
    func stop() { poller?.cancel();poller=nil }
    func send(_ operation: String,_ body: [String:any Sendable] = [:]) {
        do {
            let next=try page.request(operation,body)
            if next != snapshot { snapshot=next }
            problem=nil
        } catch { problem=error.localizedDescription }
    }
}

struct SharedFoldersView: View {
    let model: SharedFoldersModel
    let hostName: String
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted=false
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount:Int64(clamping:bytes),countStyle:.file) }
    private var writable: Bool { model.snapshot?.folder?.writable == true }
    private func chooseUpload() {
        let panel=NSOpenPanel()
        panel.canChooseDirectories=false;panel.prompt="Upload"
        panel.message="Choose a file to upload to this folder"
        if panel.runModal() == .OK,let url=panel.url { model.send("upload",["path":url.path]) }
    }
    private func download(_ entry: FoldersSnapshot.Entry) {
        let panel=NSOpenPanel()
        panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.prompt="Download Here"
        panel.message="Choose where to save \(entry.name)"
        panel.directoryURL=FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
        if panel.runModal() == .OK,let url=panel.url { model.send("download",["name":entry.name,"size":entry.size,"into":url.path]) }
    }
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        guard writable,model.snapshot?.transfer == nil,providers.count == 1,let provider=providers.first else { return false }
        _=provider.loadObject(ofClass:URL.self) { url,_ in
            guard let path=url?.path else { return }
            Task { @MainActor in model.send("upload",["path":path]) }
        }
        return true
    }
    /// Where the browser is, as a path under the folder's name.
    private var place: String {
        guard let snapshot=model.snapshot,let folder=snapshot.folder else { return "Shared Folders on \(hostName)" }
        return snapshot.path.isEmpty ? folder.name : "\(folder.name)/\(snapshot.path)"
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Button("Back",systemImage:"chevron.left") { model.send("up") }
                    .labelStyle(.iconOnly).disabled(model.snapshot?.folder == nil)
                Text(place).font(.headline).lineLimit(1).truncationMode(.head)
                if let folder=model.snapshot?.folder { Text(folder.writable ? "Read and write" : "Read only").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.snapshot?.loading == true { ProgressView().controlSize(.small) }
                Button("Refresh",systemImage:"arrow.clockwise") { model.send("list") }
                    .labelStyle(.iconOnly).disabled(model.snapshot?.loading != false)
            }.padding(12)
            Divider()
            if let refusal=model.snapshot?.refusal {
                ContentUnavailableView("No Shared Folders",systemImage:"externaldrive.badge.questionmark",description:Text(refusal))
                    .frame(maxHeight:.infinity)
            } else { Form {
                status
                if let snapshot=model.snapshot,snapshot.refusal == nil {
                    if snapshot.folder == nil { folders(snapshot) } else { entries(snapshot) }
                }
            }
            .formStyle(.grouped)
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius:8).strokeBorder(Color.accentColor,lineWidth:3).padding(4).allowsHitTesting(false) } }
            .onDrop(of:[.fileURL],isTargeted:$dropTargeted,perform:dropped)
            }
            Divider()
            HStack {
                Text(model.snapshot?.transfer == nil ? "" : "Closing cancels the transfer.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if writable { Button("Upload File…",action:chooseUpload).disabled(model.snapshot?.transfer != nil) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth:560,idealWidth:620,minHeight:460,idealHeight:560)
        .navigationTitle("Shared Folders on \(hostName)")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
    @ViewBuilder private var status: some View {
        if let message=model.problem ?? model.snapshot?.error { Section { Text(message).foregroundStyle(.red) } }
        if let transfer=model.snapshot?.transfer {
            Section {
                LabeledContent {
                    Button("Cancel") { model.send("cancel") }
                } label: {
                    Text("\(transfer.upload ? "Uploading" : "Downloading") \(transfer.name)")
                    Text("\(size(transfer.done)) of \(size(transfer.total))")
                    ProgressView(value:transfer.total == 0 ? 0 : Double(transfer.done)/Double(transfer.total))
                }
            }
        }
        if let error=model.snapshot?.transferError { Section { Text(error).foregroundStyle(.red) } }
        if let done=model.snapshot?.done { Section { Text(done) } }
    }
    @ViewBuilder private func folders(_ snapshot: FoldersSnapshot) -> some View {
        Section {
            if !snapshot.loading,snapshot.error == nil,snapshot.folders.isEmpty {
                Text("The PC shares no folders with this Mac.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.folders) { folder in
                LabeledContent {
                    Button("Open") { model.send("enterFolder",["id":folder.id]) }
                } label: {
                    Label(folder.name,systemImage:"folder")
                    Text(folder.writable ? "Read and write" : "Read only")
                }
            }
        }
    }
    @ViewBuilder private func entries(_ snapshot: FoldersSnapshot) -> some View {
        Section {
            if let entries=snapshot.entries {
                if entries.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    LabeledContent {
                        if entry.directory { Button("Open") { model.send("enterDir",["name":entry.name]) } }
                        else { Button("Download…") { download(entry) }.disabled(snapshot.transfer != nil) }
                    } label: {
                        Label(entry.name,systemImage:entry.directory ? "folder" : "doc")
                        if !entry.directory { Text(size(entry.size)) }
                    }
                }
            }
        }
    }
}
