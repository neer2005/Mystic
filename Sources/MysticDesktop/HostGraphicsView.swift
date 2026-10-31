import SwiftUI
import MysticKit

struct HostGraphicsView: View {
    @Bindable var model: ConnectionModel
    @State private var restorePanel: HostGraphics?
    @State private var restoreSession: HostSession?
    @State private var restoreContext: UUID?
    @State private var confirmingRestore=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if let panel=model.graphics.panel {
                if let notice=panel.notice { Text(notice).foregroundStyle(.secondary) }
                ForEach(panel.gpus) { gpu in
                    Text(gpu.name).font(.headline)
                    Text("Driver \(gpu.driver)").font(.caption).foregroundStyle(.secondary)
                    ForEach(gpu.settings) { setting in
                        GraphicsSettingView(model:model,gpu:gpu.id,setting:setting)
                        Divider()
                    }
                }
                Text("Changes apply to the host. The host restores temporary changes when the session ends; Disconnect keeps them for resume.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore My Graphics Changes",systemImage:"arrow.uturn.backward") {
                    restorePanel=panel;restoreSession=model.graphics.session
                    restoreContext=model.contextID;confirmingRestore=true
                }.disabled(!model.graphics.canWrite || !panel.gpus.contains { $0.settings.contains { $0.restore != nil } })
            } else if let error=model.graphics.loadError {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            } else if model.graphics.supported == false {
                Text("This host does not offer Radeon graphics controls.").foregroundStyle(.secondary)
            } else { ProgressView("Reading host graphics settings…") }
            if let error=model.graphics.writeError { Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if model.graphics.writing { ProgressView("Applying and reading host settings…") }
            Button("Refresh Graphics",systemImage:"arrow.clockwise") { Task { await model.graphics.refresh() } }
                .disabled(model.isBusy || model.graphics.reading || (model.phase != .ready && model.phase != .streaming))
        }
        .confirmationDialog("Restore my graphics changes?",isPresented:$confirmingRestore,titleVisibility:.visible) {
            if let panel=restorePanel,let session=restoreSession,let context=restoreContext {
                Button("Restore Changes") { Task { await model.graphics.restore(panel:panel,session:session,context:context) } }
            }
            Button("Cancel",role:.cancel) {}
        } message: { Text("Restore the original values for changes made by this device on the host.") }
        .task {
            while !Task.isCancelled {
                guard model.phase == .ready || model.phase == .streaming else { return }
                await model.graphics.refresh()
                if model.graphics.supported == false { return }
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
    }
}

private struct GraphicsSettingView: View {
    let model: ConnectionModel
    let gpu: Int32
    let setting: HostGraphics.Setting
    @State private var number=""
    private var editable: Bool { model.graphics.canWrite && setting.editable }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            if setting.kind == "toggle",case .toggle(let current)=setting.value {
                Toggle(setting.title,isOn:Binding(get:{current},set:{apply(.toggle($0))})).disabled(!editable)
            } else if setting.kind == "choice",case .choice(let current)=setting.value,let options=setting.options,!options.isEmpty {
                Picker(setting.title,selection:Binding(get:{current},set:{apply(.choice($0))})) {
                    if !options.contains(where: { $0.value == current }) { Text(current).tag(current) }
                    ForEach(options,id:\.value) { Text($0.label.isEmpty ? $0.value : $0.label).tag($0.value) }
                }.disabled(!editable)
            } else if setting.kind == "integer",case .integer=setting.value,let range=setting.range {
                Text(setting.title)
                HStack {
                    TextField(setting.unit ?? "Value",text:$number).textFieldStyle(.roundedBorder).frame(maxWidth:130)
                        .accessibilityLabel(setting.title).disabled(!editable)
                    Button("Apply") { if let n=Int64(number) { apply(.integer(n)) } }
                        .disabled(!editable || Int64(number).map { !setting.accepts(.integer($0)) || setting.value == .integer($0) } ?? true)
                }
                Text("\(range.min)–\(range.max) \(setting.unit ?? "") · step \(range.step)").font(.caption).foregroundStyle(.secondary)
            } else { LabeledContent(setting.title,value:setting.valueText) }
            if let note=setting.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let restore=setting.restore {
                Text("Restores to \(restore.original.text)\(setting.unit.map { " "+$0 } ?? "") when the session ends.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { syncNumber() }
        .onChange(of:setting.value) { syncNumber() }
    }
    private func syncNumber() { if case .integer(let n)=setting.value { number=String(n) } }
    private func apply(_ value: GraphicsValue) {
        let context=model.contextID
        Task { await model.graphics.write(gpu:gpu,setting:setting.id,value:value,context:context) }
    }
}
