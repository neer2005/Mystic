import SwiftUI
import MysticKit

struct HostSessionView: View {
    @Bindable var model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var tab="session"
    @State private var confirmation: HostSessionAction?
    @State private var confirmationSession: HostSession?
    @State private var confirmationContext: UUID?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Session and Graphics").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Panel",selection:$tab) {
                Text("Session").tag("session")
                Text("Graphics").tag("graphics")
                Text("Stream").tag("stream")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if tab == "stream" { LiveRatesView(model:model);HostAudioView(audio:model.hostAudioControls) }
                    else if tab == "graphics" { HostGraphicsView(model:model) }
                    else { sessionContent }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:520)
        }
        .padding(24).frame(width:460)
        .confirmationDialog(confirmation?.title ?? "Host Session",isPresented:Binding(get:{confirmation != nil},set:{if !$0 { confirmation=nil }}),titleVisibility:.visible) {
            if let action=confirmation,let expected=confirmationSession,let context=confirmationContext {
                Button(action.title,role:action == .closeGame ? .destructive : nil) {
                    Task { await model.sessionControls.perform(action,expected:expected,context:context) }
                }
            }
            Button("Cancel",role:.cancel) {}
        } message: { Text(confirmation?.explanation ?? "") }
        .task(id:tab) {
            guard tab == "session" else { return }
            while !Task.isCancelled {
                guard model.phase == .ready || model.phase == .streaming else { return }
                await model.sessionControls.refresh()
                if model.sessionControls.supported == false { return }
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
            }
        }
    }
    private var sessionContent: some View {
        VStack(alignment:.leading,spacing:16) {
            if let session=model.sessionControls.snapshot {
                LabeledContent("Game",value:session.app?.title ?? "No game")
                LabeledContent("State",value:session.state.capitalized)
                LabeledContent("Owner",value:session.owner == "you" ? "This device" : session.owner.capitalized)
                if model.phase == .ready,let id=session.app?.app_id,model.library.apps.contains(where: { $0.id == id }) {
                    Button("Resume Stream",systemImage:"play.fill") {
                        model.sessionControls.resume()
                        if model.hasSession { dismiss();openWindow(id:"stream") }
                    }.disabled(!session.actions.contains { $0.id == "resume" && $0.allowed } || model.isBusy)
                }
                Divider()
                ForEach(HostSessionAction.allCases) { action in
                    VStack(alignment:.leading,spacing:4) {
                        Button(action.title,role:action == .closeGame ? .destructive : nil) {
                            confirmationContext=model.contextID;confirmationSession=session;confirmation=action
                        }.disabled(!model.sessionControls.canControl || !session.allows(action))
                        Text(session.blockedReason(action) ?? action.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if model.sessionControls.message == nil {
                if model.phase == .ready || model.phase == .streaming { ProgressView("Reading host session…") }
                else { Text(model.status).foregroundStyle(.secondary) }
            }
            if let message=model.sessionControls.message {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if model.sessionControls.busy { ProgressView().controlSize(.small);Text("Waiting for host…") }
                Spacer()
                Button("Refresh",systemImage:"arrow.clockwise") { Task { await model.sessionControls.refresh() } }
                    .disabled(model.isBusy || (model.phase != .ready && model.phase != .streaming))
            }
        }
    }

}
