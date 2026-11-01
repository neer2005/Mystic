import Foundation

/// Keeps the Mac's display from dimming or sleeping while a stream runs. Playing can mean no
/// input on this Mac at all, such as with a controller plugged into the PC, and macOS would
/// otherwise take the stream for an idle screen. Nightjar gets the same from SDL, which keeps
/// the screen saver off while its window is open.
@MainActor
final class DisplayWake {
    private var activity: (any NSObjectProtocol)?
    private let begin: () -> any NSObjectProtocol
    private let end: (any NSObjectProtocol) -> Void
    init(begin: @escaping () -> any NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options:[.idleDisplaySleepDisabled,.userInitiated],reason:"Streaming a game")
         },
         end: @escaping (any NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin=begin;self.end=end
    }
    var held: Bool { activity != nil }
    func update(streaming: Bool) {
        if streaming,activity == nil { activity=begin() }
        else if !streaming,let activity { end(activity);self.activity=nil }
    }
    isolated deinit { if let activity { end(activity) } }
}
