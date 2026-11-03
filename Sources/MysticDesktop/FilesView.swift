import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MysticKit

/// A PC's Files page: send files to its transfer folder, download from it, with progress, cancel
/// and the reason for each refusal. Closing it cancels what has not finished, as on Nightjar.
@MainActor @Observable
final class FilesModel: Identifiable {
    private(set) var snapshot: FilesSnapshot?
    private(set) var notices: [String]=[]
    private(set) var problem: String?
    private let page: any FilesPage
    @ObservationIgnored private var poller: Task<Void,Never>?
    init(page: any FilesPage) { self.page=page }
    func start() {
        guard poller == nil else { return }
        apply { try page.snapshot() }
        poller=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.milliseconds(100))
                self?.apply { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try self.page.snapshot()
                }
            }
        }
    }
    func stop() { poller?.cancel();poller=nil }
    func apply(_ work: () throws -> FilesSnapshot) {
        do {
            let next=try work()
            notices.append(contentsOf:next.notices)
            if next != snapshot { snapshot=next }
            problem=nil
        } catch is CancellationError {} catch { problem=error.localizedDescription }
    }
    func send(_ files: [URL]) { apply { try page.send(files) } }
    func download(_ file: FilesSnapshot.RemoteFile) { apply { try page.download(name:file.name,size:file.size) } }
    func cancel(_ id: UInt64) { apply { try page.cancel(id) } }
    func retry(_ id: UInt64) { apply { try page.retry(id) } }
    func refresh() { apply { try page.refresh() } }
    func checkAgain() { apply { try page.checkAgain() } }
    func clearFinished() { notices=[];apply { try page.clearFinished() } }
    var hasFinished: Bool { snapshot?.transfers.contains(where:\.finished) == true || !notices.isEmpty }
}

struct FilesView: View {
    let model: FilesModel
    let hostName: String
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted=false
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount:Int64(clamping:bytes),countStyle:.file) }
    private func choose() {
        let panel=NSOpenPanel()
        panel.allowsMultipleSelection=true;panel.canChooseDirectories=false;panel.prompt="Send"
        panel.message="Choose files to send to \(hostName)"
        if panel.runModal() == .OK { model.send(panel.urls) }
    }
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        guard model.snapshot?.mayUpload == true else { return false }
        for provider in providers {
            _=provider.loadObject(ofClass:URL.self) { url,_ in
                guard let url else { return }
                Task { @MainActor in model.send([url]) }
            }
        }
        return true
    }
    private var active: Bool { model.snapshot?.active == true }
    var body: some View {
        VStack(spacing:0) {
            Text("Files on \(hostName)").font(.headline).frame(maxWidth:.infinity,alignment:.leading).padding(12)
            Divider()
            if let snapshot=model.snapshot,snapshot.access == "known",!snapshot.mayUpload,!snapshot.mayDownload {
                ContentUnavailableView("No File Transfer",systemImage:"folder.badge.questionmark",
                    description:Text("\(hostName) doesn't offer file transfer to this Mac. You can turn it on in the PC's web UI, under Devices."))
                    .frame(maxHeight:.infinity)
            } else { Form {
                if let problem=model.problem { Text(problem).foregroundStyle(.red) }
                switch model.snapshot?.access {
                case "known": known
                case "failed":
                    Section {
                        Text("Could not ask the PC: \(model.snapshot?.accessError ?? "")").foregroundStyle(.red)
                        Button("Try Again") { model.checkAgain() }
                    }
                default: Section { ProgressView("Asking the PC…") }
                }
                transfers
            }
            .formStyle(.grouped)
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius:8).strokeBorder(Color.accentColor,lineWidth:3).padding(4).allowsHitTesting(false) } }
            .onDrop(of:[.fileURL],isTargeted:$dropTargeted,perform:dropped)
            }
            Divider()
            HStack {
                Text(active ? "Closing cancels unfinished transfers." : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hasFinished { Button("Clear Finished") { model.clearFinished() } }
                if model.snapshot?.mayUpload == true { Button("Send Files…",action:choose) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth:560,idealWidth:620,minHeight:460,idealHeight:560)
        .navigationTitle("Files on \(hostName)")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
    @ViewBuilder private var known: some View {
        if let snapshot=model.snapshot {
            if let refusal=snapshot.uploadRefusal { Section { Text(refusal).foregroundStyle(.secondary) } }
            if let refusal=snapshot.downloadRefusal { Section { Text(refusal).foregroundStyle(.secondary) } }
            if snapshot.mayUpload || snapshot.mayDownload {
                Section {
                    if let error=snapshot.listError { Text(error).foregroundStyle(.red) }
                    else if let list=snapshot.list {
                        if list.files.isEmpty { Text("No files in the PC's folder yet.").foregroundStyle(.secondary) }
                        ForEach(list.files) { file in
                            LabeledContent {
                                if snapshot.mayDownload { Button("Download") { model.download(file) } }
                            } label: {
                                Text(file.name)
                                Text("\(size(file.size)) · \(Date(timeIntervalSince1970:Double(file.modifiedMs)/1000).formatted(date:.abbreviated,time:.shortened))")
                            }
                        }
                    } else { ProgressView("Reading the PC's folder…") }
                } header: {
                    HStack {
                        Text("On the PC")
                        Spacer()
                        Button("Refresh",systemImage:"arrow.clockwise") { model.refresh() }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(snapshot.listing)
                    }
                } footer: {
                    if let list=snapshot.list {
                        Text("\(list.folder) · \(size(list.freeBytes)) free · up to \(size(list.maxFileBytes)) a file. Downloads go to your Downloads folder.")
                    }
                }
            }
        }
    }
    @ViewBuilder private var transfers: some View {
        if !(model.snapshot?.transfers ?? []).isEmpty || !model.notices.isEmpty {
            Section("Transfers") {
                ForEach(model.notices,id:\.self) { Text($0).foregroundStyle(.red) }
                ForEach(model.snapshot?.transfers ?? []) { transfer in
                    FileTransferRow(transfer:transfer,downloads:model.snapshot?.downloads,cancel:{ model.cancel(transfer.id) },retry:{ model.retry(transfer.id) })
                }
            }
        }
    }
}

private struct FileTransferRow: View {
    let transfer: FilesSnapshot.Transfer
    let downloads: String?
    let cancel: () -> Void
    let retry: () -> Void
    var body: some View {
        LabeledContent {
            HStack {
                if let saved=transfer.savedName,let downloads {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:downloads).appendingPathComponent(saved)]) }
                }
                if transfer.canRetry { Button("Try Again",action:retry) }
                if !transfer.finished { Button("Cancel",action:cancel).disabled(transfer.cancelling) }
            }
        } label: {
            Label(transfer.title,systemImage:transfer.upload ? "arrow.up.circle" : "arrow.down.circle")
            Text(transfer.status).foregroundStyle(transfer.failed ? .red : .secondary).help(transfer.detail ?? "")
            if !transfer.finished,let fraction=transfer.fraction { ProgressView(value:fraction) }
        }
    }
}
