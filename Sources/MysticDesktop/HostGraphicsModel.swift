import Foundation
import Observation
import MysticKit

/// The host's Radeon graphics panel for the connected PC: read-back, writes and restore.
@MainActor @Observable
public final class HostGraphicsModel {
    public private(set) var panel: HostGraphics?
    public private(set) var session: HostSession?
    public private(set) var loadError: String?
    public private(set) var writeError: String?
    public private(set) var supported: Bool?
    public private(set) var writing=false
    public private(set) var reading=false
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }

    public var canWrite: Bool {
        (model.phase == .ready || model.phase == .streaming) && model.pendingGameAction == nil && !model.rates.busy
            && !model.sessionControls.busy && !writing && !reading
            && panel?.writable == true && session?.owner == "you"
            && ["streaming","suspended"].contains(session?.state ?? "")
    }
    func reset() {
        panel=nil;session=nil;loadError=nil;writeError=nil
        supported=nil;writing=false;reading=false
    }
    public func refresh() async {
        guard let connection=model.connection,!reading,!writing,!model.sessionControls.busy,model.phase == .ready || model.phase == .streaming else { return }
        let token=model.generation
        reading=true
        defer { if model.generation == token { reading=false } }
        do {
            let panel=try await connection.graphics()
            let session=panel == nil ? nil : try await connection.hostSession()
            guard model.generation == token else { return }
            self.panel=panel;self.session=session;supported=panel != nil;loadError=nil
        } catch {
            guard model.generation == token else { return }
            panel=nil;session=nil;loadError=error.localizedDescription
        }
    }
    public func write(gpu: Int32,setting: String,value: GraphicsValue,context: UUID) async {
        guard context == model.generation,canWrite,let panel,let session,
            panel.gpus.first(where: { $0.id == gpu })?.settings.first(where: { $0.id == setting })?.accepts(value) == true else { return }
        await change(panel:panel,session:session,gpu:gpu,setting:setting,value:value)
    }
    public func restore(panel: HostGraphics,session: HostSession,context: UUID) async {
        guard context == model.generation,canWrite,self.panel?.revision == panel.revision else { return }
        await change(panel:panel,session:session,gpu:nil,setting:nil,value:nil)
    }
    private func change(panel: HostGraphics,session: HostSession,gpu: Int32?,setting: String?,value: GraphicsValue?) async {
        guard let connection=model.connection else { return }
        let token=model.generation
        writing=true;writeError=nil
        model.inputCapture?.release()
        defer { if model.generation == token { writing=false } }
        do {
            let updated: HostGraphics
            if let gpu,let setting,let value {
                updated=try await connection.writeGraphics(gpu:gpu,setting:setting,value:value,expected:panel,session:session)
            } else { updated=try await connection.restoreGraphics(expected:panel,session:session) }
            guard model.generation == token else { return }
            self.panel=updated;loadError=nil
        } catch {
            guard model.generation == token else { return }
            writeError=error.localizedDescription
            // A driver can partially apply a request before reporting failure. Read the host back.
            do {
                let current=try await connection.graphics()
                guard model.generation == token else { return }
                self.panel=current
            } catch {
                guard model.generation == token else { return }
                self.panel=nil;loadError=error.localizedDescription
            }
        }
    }
}
