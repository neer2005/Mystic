import AppKit
import GameController

/// Lets a game controller drive the library, as the HIG's "Game controls" asks of any game UI
/// outside gameplay: the D-pad or left stick moves the selection, A activates, B cancels or
/// goes back, the shoulder buttons move between sections and Menu opens settings.
///
/// The pad's presses become the keys a Mac user would press (arrows, Return, Escape) in the
/// key window, so every view keeps the keyboard behavior it already has: the game grid and the
/// list select and start, a sheet's default button answers A, and Escape dismisses it on B.
///
/// It runs only while no stream does. During a stream the pads belong to the PC: the handlers
/// here are removed before `StreamControllers` takes them, so nothing extra runs on the
/// controller queue the stream's input uses, and no key can reach the stream window.
@MainActor
final class LibraryControllerNavigation {
    /// The game grid on screen, focused when a press arrives and nothing that takes arrows has
    /// the keyboard. Home and a PC's library never show their grids at once.
    static weak var visibleGrid: NSView?
    /// LB (-1) and RB (+1): the sidebar's previous or next section.
    var switchSection: (Int) -> Void={ _ in }
    var openSettings: () -> Void={}
    private var active=false
    private var observers: [any NSObjectProtocol]=[]
    private var pads: [ObjectIdentifier:PadState]=[:]
    private var repeating: Task<Void,Never>?

    init() {
        let center=NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect,.GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach() }
            })
        }
    }
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        setActive(false)
    }

    /// On while the library may take input; off for the length of every stream.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active=value
        if value { attach() }
        else {
            for controller in GCController.controllers() { Self.detach(controller) }
            pads.removeAll();stopRepeat()
        }
    }

    private func attach() {
        guard active else { return }
        let connected=GCController.controllers().filter { $0.extendedGamepad != nil }
        pads=pads.filter { key,_ in connected.contains { ObjectIdentifier($0) == key } }
        for controller in connected where pads[ObjectIdentifier(controller)] == nil {
            pads[ObjectIdentifier(controller)]=PadState()
            install(controller)
        }
    }
    /// Element handlers only: `StreamControllers` owns the pad's `valueChangedHandler`. The
    /// handlers run on whatever queue the pad was given and hop to the main actor.
    private func install(_ controller: GCController) {
        guard let pad=controller.extendedGamepad else { return }
        let key=ObjectIdentifier(controller)
        let button: (Action) -> GCControllerButtonValueChangedHandler={ [weak self] action in
            { [weak self] _,_,pressed in
                guard pressed else { return }
                Task { @MainActor in self?.perform(action) }
            }
        }
        pad.buttonA.valueChangedHandler=button(.activate)
        pad.buttonB.valueChangedHandler=button(.cancel)
        pad.leftShoulder.valueChangedHandler=button(.section(-1))
        pad.rightShoulder.valueChangedHandler=button(.section(1))
        pad.buttonMenu.valueChangedHandler=button(.settings)
        let direction: GCControllerDirectionPadValueChangedHandler={ [weak self] _,x,y in
            Task { @MainActor in self?.steer(key,x:x,y:y) }
        }
        pad.dpad.valueChangedHandler=direction
        pad.leftThumbstick.valueChangedHandler=direction
    }
    private static func detach(_ controller: GCController) {
        guard let pad=controller.extendedGamepad else { return }
        for button in [pad.buttonA,pad.buttonB,pad.leftShoulder,pad.rightShoulder,pad.buttonMenu] { button.valueChangedHandler=nil }
        pad.dpad.valueChangedHandler=nil;pad.leftThumbstick.valueChangedHandler=nil
    }

    enum Action: Equatable { case activate,cancel,section(Int),settings,move(GridNavigation.Move) }
    private func perform(_ action: Action) {
        guard active,NSApp.isActive else { return }
        switch action {
        case .activate: press(.return)
        case .cancel: press(.escape)
        case .section(let step): switchSection(step)
        case .settings: openSettings()
        case .move(let move):
            focusGridIfNeeded()
            press(Key(move))
        }
    }
    private func steer(_ key: ObjectIdentifier,x: Float,y: Float) {
        guard active,var state=pads[key] else { return }
        let before=state.direction
        state.direction=ControllerSteering.direction(x:x,y:y,current:before)
        pads[key]=state
        guard state.direction != before else { return }
        stopRepeat()
        guard let move=state.direction else { return }
        perform(.move(move))
        // A held direction repeats as a held arrow key does.
        repeating=Task { @MainActor [weak self] in
            try? await Task.sleep(for:ControllerSteering.repeatDelay)
            while !Task.isCancelled {
                self?.perform(.move(move))
                try? await Task.sleep(for:ControllerSteering.repeatInterval)
            }
        }
    }
    private func stopRepeat() { repeating?.cancel();repeating=nil }
    /// Arrows do nothing while the search field or nothing at all has the keyboard; the grid,
    /// or a list already holding it, is where a pad's direction is meant to go.
    private func focusGridIfNeeded() {
        guard let window=NSApp.keyWindow,let grid=Self.visibleGrid,grid.window === window else { return }
        let responder=window.firstResponder
        if responder is NSTableView || responder is NSOutlineView || responder === grid { return }
        window.makeFirstResponder(grid)
    }

    private enum Key {
        case left,right,up,down,`return`,escape
        init(_ move: GridNavigation.Move) {
            switch move { case .left: self = .left;case .right: self = .right;case .up: self = .up;case .down: self = .down }
        }
        var code: UInt16 {
            switch self { case .left: 123;case .right: 124;case .down: 125;case .up: 126;case .return: 36;case .escape: 53 }
        }
        var characters: String {
            let scalar: Int
            switch self {
            case .left: scalar=NSLeftArrowFunctionKey;case .right: scalar=NSRightArrowFunctionKey
            case .up: scalar=NSUpArrowFunctionKey;case .down: scalar=NSDownArrowFunctionKey
            case .return: scalar=0x0D;case .escape: scalar=0x1B
            }
            return String(Character(UnicodeScalar(scalar)!))
        }
        var flags: NSEvent.ModifierFlags { [.left,.right,.up,.down].contains(self) ? [.numericPad,.function] : [] }
    }
    private func press(_ key: Key) {
        guard let window=NSApp.keyWindow else { return }
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            guard let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:key.flags,timestamp:ProcessInfo.processInfo.systemUptime,
                                             windowNumber:window.windowNumber,context:nil,characters:key.characters,
                                             charactersIgnoringModifiers:key.characters,isARepeat:false,keyCode:key.code) else { continue }
            window.sendEvent(event)
        }
    }
    private struct PadState { var direction: GridNavigation.Move? }
}

/// Stick and D-pad to a direction, separate from the handlers so it can be tested.
enum ControllerSteering {
    static let repeatDelay=Duration.milliseconds(400)
    static let repeatInterval=Duration.milliseconds(120)
    /// A direction starts past `press` and holds until the stick falls back inside `release`,
    /// so a stick resting near the threshold doesn't flicker between moves.
    static let press: Float=0.6
    static let release: Float=0.35
    static func direction(x: Float,y: Float,current: GridNavigation.Move?) -> GridNavigation.Move? {
        let magnitude=max(abs(x),abs(y))
        if let current,magnitude >= release,dominant(x:x,y:y) == current { return current }
        guard magnitude >= press else { return nil }
        return dominant(x:x,y:y)
    }
    private static func dominant(x: Float,y: Float) -> GridNavigation.Move {
        abs(x) > abs(y) ? (x < 0 ? .left : .right) : (y > 0 ? .up : .down)
    }
}
