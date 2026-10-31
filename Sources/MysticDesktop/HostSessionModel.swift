import Foundation
import Observation
import MysticKit

/// The host's native session controls: status, owner, resume and host-authorized exits.
@MainActor @Observable
public final class HostSessionModel {
    public private(set) var snapshot: HostSession?
    public private(set) var message: String?
    public private(set) var supported: Bool?
    public private(set) var busy=false
    @ObservationIgnored private var reading=false
    @ObservationIgnored private var terminated=false
    @ObservationIgnored private unowned let model: ConnectionModel
    init(model: ConnectionModel) { self.model=model }

    public var canControl: Bool {
        (model.phase == .ready || model.phase == .streaming) && !model.isBusy && snapshot != nil
    }
    func reset() {
        snapshot=nil;message=nil;supported=nil;busy=false;reading=false;terminated=false
    }
    /// Recovery drops the snapshot but keeps an in-flight action's outcome.
    func suspend() { snapshot=nil;reading=false;supported=nil }
    /// The stream ended while an action was in flight; its failure then ends the connection.
    func streamTerminated() { terminated=true }

    public func refresh() async {
        guard let connection=model.connection,!reading,!busy,!model.graphics.writing,model.phase == .ready || model.phase == .streaming else { return }
        let token=model.generation
        reading=true
        defer { if model.generation == token { reading=false } }
        do {
            let value=try await connection.hostSession()
            guard model.generation == token,!busy else { return }
            snapshot=value;supported=value != nil
            message=value == nil ? "This host does not offer native session controls. Use Disconnect to leave the stream." : nil
        } catch {
            guard model.generation == token else { return }
            snapshot=nil;message=error.localizedDescription
        }
    }
    public func perform(_ action: HostSessionAction,expected given: HostSession? = nil,context: UUID? = nil) async {
        guard context == nil || context == model.generation else { return }
        guard canControl,let connection=model.connection,let expected=given ?? snapshot,expected.allows(action) else { return }
        let token=model.generation
        busy=true;terminated=false;message=nil
        model.inputCapture?.release()
        do {
            _ = try await connection.performSessionAction(action,expected:expected)
            guard model.generation == token else { return }
            // An intentional host exit must never launch automatic reconnect.
            switch action {
            case .closeGame: model.hostEnded("The game was closed on the host.")
            case .end: model.hostEnded("Host session ended. The game remains running.")
            case .disconnect: model.hostEnded("Host session suspended. The game remains running.")
            }
        } catch {
            guard model.generation == token else { return }
            busy=false;snapshot=nil
            if terminated { model.endStream(error.localizedDescription) }
            else { message=error.localizedDescription }
        }
        if model.generation == token { busy=false }
    }
    public func resume() {
        guard model.phase == .ready,!busy,let snapshot,
            snapshot.actions.contains(where: { $0.id == "resume" && $0.allowed }),
            let id=snapshot.app?.app_id,model.library.apps.contains(where: { $0.id == id }) else { return }
        model.library.selectedID=id;model.play()
    }
}
