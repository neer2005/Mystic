import Foundation
import GameController
import MysticCore

/// Handlers live on the main queue alongside capture focus. Extended profiles provide
/// positional face buttons for both Xbox and PlayStation controllers. Up to 16 controllers,
/// as Nightjar; the engine folds them to four for hosts that take no more.
@MainActor
final class StreamControllers {
    static let slots=16
    private var devices: [Int:GCController] = [:]
    private let connectedDevices: () -> [GCController]
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private var haptics: [Int:any ControllerHaptics] = [:]
    private let makeHaptics: (GCController) -> (any ControllerHaptics)?
    private var extras: [Int:any ControllerExtras] = [:]
    private let makeExtras: (GCController) -> any ControllerExtras
    private let feedbackFailure: (String) -> Void
    private(set) var feedbackEpoch: UInt64 = 0
    private let send: (RemoteInputEvent) -> Bool
    private let failure: () -> Void
    /// Nightjar's controller mouse per slot, the physical buttons last seen for the leave combo,
    /// and the last state, which the mouse's sticks keep moving with between changes.
    private var mice: [Int:ControllerMouse] = [:]
    private var physical: [Int:UInt32] = [:]
    private var lastState: [Int:ControllerState] = [:]
    private var guides: [Int:GuideHold] = [:]
    private var mouseTimer: Timer?
    private let nowMillis: () -> UInt64
    /// The leave combo was pressed.
    var leave: () -> Void = {}
    /// Guide was held for the setting's time.
    var guideHeld: () -> Void = {}
    /// Controller mouse mode switched on (true) or off (false).
    var mouseSwitched: (Bool) -> Void = { _ in }
    var mouseActive: Bool { mice.values.contains { $0.active } }
    var settings=InputPreferences() {
        didSet {
            guard settings != oldValue,enabled else { return }
            if settings.disableVibration,!oldValue.disableVibration { silenceMotors() }
            if settings.controllerMotion != oldValue.controllerMotion {
                if !settings.controllerMotion {
                    for extra in extras.values { extra.setMotion(.accelerometer,rateHz:0);extra.setMotion(.gyroscope,rateHz:0) }
                }
                // The host learns what the pads can do from their arrivals.
                for slot in devices.keys.sorted() {
                    guard let device=devices[slot],emit(arrival(slot:slot,device:device)) else { return }
                }
            }
            for slot in devices.keys.sorted() { submit(slot:slot) }
        }
    }
    init(connectedDevices: @escaping () -> [GCController] = { GCController.controllers() },
         makeHaptics: @escaping (GCController) -> (any ControllerHaptics)? = { NativeControllerHaptics(controller:$0) },
         makeExtras: @escaping (GCController) -> any ControllerExtras = { NativeControllerExtras(controller:$0) },
         feedbackFailure: @escaping (String) -> Void = { _ in },
         nowMillis: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds/1_000_000 },
         send: @escaping (RemoteInputEvent) -> Bool, failure: @escaping () -> Void) {
        self.send=send;self.failure=failure;self.connectedDevices=connectedDevices;self.nowMillis=nowMillis
        self.makeHaptics=makeHaptics;self.makeExtras=makeExtras;self.feedbackFailure=feedbackFailure
        let center=NotificationCenter.default
        for name in [NSNotification.Name.GCControllerDidConnect,NSNotification.Name.GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    isolated deinit {
        mouseTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for controller in devices.values { controller.extendedGamepad?.valueChangedHandler=nil }
        for feedback in haptics.values { feedback.stop() }
        for extra in extras.values { extra.stop() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled=value;feedbackEpoch &+= 1
        if value { refresh() }
        else {
            for controller in devices.values { controller.extendedGamepad?.valueChangedHandler=nil }
            for feedback in haptics.values { feedback.stop() };haptics.removeAll()
            for extra in extras.values { extra.stop() };extras.removeAll()
            devices.removeAll()
            // Capture's releaseAll lets go of the mouse's clicks too.
            let wasActive=mouseActive
            mice.removeAll();physical.removeAll();lastState.removeAll();guides.removeAll();updateMouseTimer()
            if wasActive { mouseSwitched(false) }
            // Capture's releaseAll neutralizes states actually accepted by the worker.
        }
    }
    /// Controllers switched on or off in Settings during a stream; the host's pads go neutral.
    func setActive(_ value: Bool) {
        if !value { for slot in devices.keys.sorted() { guard emit(.controller(slot:UInt8(slot),activeMask:0,state:ControllerState())) else { return } } }
        setEnabled(value)
    }
    private func silenceMotors() {
        for (slot,feedback) in haptics {
            for kind in [ControllerFeedback.Kind.rumble,.triggerRumble] { try? feedback.apply(ControllerFeedback(slot:UInt8(slot),kind:kind,first:0,second:0)) }
        }
    }
    private var mask: UInt16 { devices.keys.reduce(0) { $0 | (1 << $1) } }
    func refresh() {
        guard enabled else { return }
        let connected=connectedDevices().filter { $0.extendedGamepad != nil }
        var changed=false
        for slot in devices.keys.sorted() {
            guard let device=devices[slot],!connected.contains(where: { $0 === device }) else { continue }
            device.extendedGamepad?.valueChangedHandler=nil
            haptics.removeValue(forKey:slot)?.stop()
            extras.removeValue(forKey:slot)?.stop()
            devices.removeValue(forKey:slot);changed=true
            physical.removeValue(forKey:slot);lastState.removeValue(forKey:slot);guides.removeValue(forKey:slot)
            if var mouse=mice.removeValue(forKey:slot) {
                for event in mouse.release() { guard emit(event) else { return } }
                if mouse.active { updateMouseTimer();mouseSwitched(mouseActive) }
            }
            guard emit(.controller(slot:UInt8(slot),activeMask:mask,state:ControllerState())) else { return }
        }
        for device in connected where !devices.values.contains(where: { $0 === device }) {
            guard let slot=(0..<Self.slots).first(where: { devices[$0] == nil }) else { break }
            devices[slot]=device;haptics[slot]=makeHaptics(device);extras[slot]=makeExtras(device);changed=true
        }
        guard changed else { return }
        feedbackEpoch &+= 1
        for slot in devices.keys.sorted() {
            guard enabled,let device=devices[slot] else { return }
            device.handlerQueue = .main
            guard emit(arrival(slot:slot,device:device)) else { return }
            startExtras(slot:slot,device:device)
            device.extendedGamepad?.valueChangedHandler = { [weak self,weak device] _,_ in
                MainActor.assumeIsolated {
                    guard let self,let device,self.enabled,self.devices[slot] === device else { return }
                    self.submit(slot:slot)
                }
            }
            submit(slot:slot)
        }
    }
    private func capabilities(slot: Int) -> ControllerCapabilities {
        var capabilities=(haptics[slot]?.capabilities ?? []).union(extras[slot]?.capabilities ?? []).union(.analogTriggers)
        if !settings.controllerMotion { capabilities.subtract([.accelerometer,.gyroscope]) }
        return capabilities
    }
    private func arrival(slot: Int,device: GCController) -> RemoteInputEvent {
        .controllerArrival(slot:UInt8(slot),activeMask:mask,capabilities:capabilities(slot:slot),feedbackEpoch:feedbackEpoch,
                           kind:Self.kind(device),buttons:device.extendedGamepad.map(Self.buttons) ?? ControllerButtons.classic)
    }
    /// Battery right after the arrival, as Nightjar; motion once the host asks for it.
    private func startExtras(slot: Int,device: GCController) {
        let wire=UInt8(slot)
        let current={ [weak self,weak device] in
            guard let self,let device,self.enabled else { return false };return self.devices[slot] === device
        }
        extras[slot]?.start(motion: { [weak self] kind,x,y,z in
            guard current() else { return };_=self?.emit(.controllerMotion(slot:wire,kind:kind,x:x,y:y,z:z))
        },battery: { [weak self] battery in
            guard current() else { return };_=self?.emit(.controllerBattery(slot:wire,battery:battery))
        })
    }
    func applyFeedback(_ values: [ControllerFeedback],epoch: UInt64) {
        guard enabled,epoch == feedbackEpoch else { return }
        for value in values {
            let slot=Int(value.slot)
            guard value.epoch == feedbackEpoch,devices[slot] != nil else { continue }
            switch value.kind {
            case .rumble,.triggerRumble: applyMotors(value,slot:slot)
            case .light:
                guard let extra=extras[slot],extra.capabilities.contains(.light) else { continue }
                extra.setLight(red:UInt8(value.first >> 8),green:UInt8(value.first & 0xFF),blue:UInt8(clamping:value.second))
            case .accelerometerRate,.gyroscopeRate:
                guard settings.controllerMotion else { continue }
                let kind: ControllerMotionKind = value.kind == .accelerometerRate ? .accelerometer : .gyroscope
                guard let extra=extras[slot],extra.capabilities.contains(kind == .accelerometer ? .accelerometer : .gyroscope) else { continue }
                extra.setMotion(kind,rateHz:value.first)
            }
            guard enabled else { return }
        }
    }
    private func applyMotors(_ value: ControllerFeedback,slot: Int) {
        guard !settings.disableVibration,let feedback=haptics[slot] else { return }
        let required: ControllerCapabilities=value.kind == .rumble ? .rumble : .triggerRumble
        guard feedback.capabilities.contains(required) else { return }
        do { try feedback.apply(value) }
        catch {
            feedback.stop();haptics.removeValue(forKey:slot)
            feedbackFailure("Controller feedback unavailable. Controller input remains active.")
            guard let device=devices[slot] else { return }
            _=emit(arrival(slot:slot,device:device))
        }
    }
    static func kind(_ controller: GCController) -> ControllerKind {
        switch controller.extendedGamepad {
        case is GCDualSenseGamepad,is GCDualShockGamepad: return .playStation
        case is GCXboxGamepad: return .xbox
        default:
            let category=controller.productCategory.lowercased()
            return category.contains("switch") || category.contains("joy-con") ? .nintendo : .unknown
        }
    }
    /// What this pad can press, in the same terms as `snapshot`.
    static func buttons(_ pad: GCExtendedGamepad) -> UInt32 {
        var buttons=ControllerButtons.classic
        for (element,flag) in extraButtons(pad) where element != nil { buttons |= flag }
        return buttons
    }
    private static func extraButtons(_ pad: GCExtendedGamepad) -> [(GCControllerButtonInput?,UInt32)] {
        var extra: [(GCControllerButtonInput?,UInt32)]=[(pad.buttonHome,ControllerButtons.guide)]
        if let dualSense=pad as? GCDualSenseGamepad { extra.append((dualSense.touchpadButton,ControllerButtons.touchpad)) }
        if let dualShock=pad as? GCDualShockGamepad { extra.append((dualShock.touchpadButton,ControllerButtons.touchpad)) }
        if let xbox=pad as? GCXboxGamepad {
            extra.append((xbox.buttonShare,ControllerButtons.misc))
            let paddles=[xbox.paddleButton1,xbox.paddleButton2,xbox.paddleButton3,xbox.paddleButton4]
            extra += zip(paddles,ControllerButtons.paddles).map { ($0,$1) }
        }
        return extra
    }
    private func submit(slot: Int) {
        guard enabled,let pad=devices[slot]?.extendedGamepad else { return }
        let state=Self.snapshot(pad,settings:settings)
        let raw=Self.physicalButtons(pad),previous=physical[slot] ?? 0
        physical[slot]=raw;lastState[slot]=state
        var guide=guides[slot] ?? GuideHold()
        guide.observe(state.buttons,holdMillis:settings.guideHoldMillis,nowMillis:nowMillis())
        guides[slot]=guide
        if guide.waiting { updateMouseTimer() }
        var mouse=mice[slot] ?? ControllerMouse()
        // As Nightjar: the combo's last press leaves the stream, with the pad neutral first.
        if settings.leaveCombo.completed(physical:raw,previous:previous) {
            for event in mouse.release() { guard emit(event) else { return } }
            mice[slot]=mouse
            guard emit(.controller(slot:UInt8(slot),activeMask:mask,state:ControllerState())) else { return }
            leave();return
        }
        let wasActive=mouseActive
        let (events,switched)=mouse.update(state,enabled:settings.controllerMouse,precise:settings.preciseControllerMouse,nowMillis:nowMillis())
        mice[slot]=mouse
        for event in events { guard emit(event) else { return } }
        if switched != nil,mouseActive != wasActive { updateMouseTimer();mouseSwitched(mouseActive) }
        // While the mouse is on, the PC's controller sees nothing pressed.
        emitState(slot:slot)
    }
    /// The pad's last state as the PC gets it: nothing while the mouse is on, Guide as its hold says.
    @discardableResult private func emitState(slot: Int) -> Bool {
        guard var state=lastState[slot] else { return true }
        if mice[slot]?.active == true { state=ControllerState() }
        else if let guide=guides[slot] { state.buttons=guide.output(state.buttons) }
        return emit(.controller(slot:UInt8(slot),activeMask:mask,state:state))
    }
    /// The sticks move the pointer between changes too, so a held stick keeps moving it.
    private func updateMouseTimer() {
        guard enabled,mouseActive || guides.values.contains(where: \.waiting) else { mouseTimer?.invalidate();mouseTimer=nil;return }
        guard mouseTimer == nil else { return }
        // Wakes more often than the mouse's 50 ms step, so steps don't slip to every other tick.
        mouseTimer=Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMice() }
        }
    }
    func tickMice() {
        guard enabled else { return }
        let now=nowMillis()
        for slot in guides.keys.sorted() {
            guard var guide=guides[slot],guide.waiting else { continue }
            let (opened,resend)=guide.tick(holdMillis:settings.guideHoldMillis,nowMillis:now)
            guides[slot]=guide
            if resend { guard emitState(slot:slot) else { return } }
            // Gives the Mac its input back, which disables the controllers: nothing more this tick.
            if opened { guideHeld();return }
        }
        updateMouseTimer()
        for slot in mice.keys.sorted() {
            guard var mouse=mice[slot],mouse.active else { continue }
            let events=mouse.tick(lastState[slot] ?? ControllerState(),scrollStick:settings.scrollStick,precise:settings.preciseControllerMouse,nowMillis:now)
            mice[slot]=mouse
            for event in events { guard emit(event) else { return } }
        }
    }
    @discardableResult private func emit(_ event: RemoteInputEvent) -> Bool {
        if send(event) { return true }
        setEnabled(false);failure();return false
    }
    /// The buttons held, by position (A is south), before the Nintendo layout swap.
    static func physicalButtons(_ pad: GCExtendedGamepad) -> UInt32 {
        var buttons: UInt32=0
        let mapping: [(GCControllerButtonInput?,UInt32)] = [
            (pad.dpad.up,0x1),(pad.dpad.down,0x2),(pad.dpad.left,0x4),(pad.dpad.right,0x8),
            (pad.buttonMenu,0x10),(pad.buttonOptions,0x20),
            (pad.leftThumbstickButton,0x40),(pad.rightThumbstickButton,0x80),
            (pad.leftShoulder,0x100),(pad.rightShoulder,0x200),
            (pad.buttonA,0x1000),(pad.buttonB,0x2000),(pad.buttonX,0x4000),(pad.buttonY,0x8000),
        ]
        for (button,flag) in mapping+extraButtons(pad) where button?.isPressed == true { buttons |= flag }
        return buttons
    }
    static func snapshot(_ pad: GCExtendedGamepad,settings: InputPreferences = InputPreferences()) -> ControllerState {
        var buttons=physicalButtons(pad)
        if settings.swapFaceButtons { buttons=ControllerButtons.swappingFace(buttons) }
        let left=ControllerState.stick(x:pad.leftThumbstick.xAxis.value,y:pad.leftThumbstick.yAxis.value,deadZone:settings.stickDeadZone)
        let right=ControllerState.stick(x:pad.rightThumbstick.xAxis.value,y:pad.rightThumbstick.yAxis.value,deadZone:settings.stickDeadZone)
        return ControllerState(buttons:buttons,leftTrigger:ControllerState.trigger(pad.leftTrigger.value),
                               rightTrigger:ControllerState.trigger(pad.rightTrigger.value),
                               leftX:left.0,leftY:left.1,rightX:right.0,rightY:right.1)
    }
}
