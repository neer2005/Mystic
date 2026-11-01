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
    init(connectedDevices: @escaping () -> [GCController] = { GCController.controllers() },
         makeHaptics: @escaping (GCController) -> (any ControllerHaptics)? = { NativeControllerHaptics(controller:$0) },
         makeExtras: @escaping (GCController) -> any ControllerExtras = { NativeControllerExtras(controller:$0) },
         feedbackFailure: @escaping (String) -> Void = { _ in },
         send: @escaping (RemoteInputEvent) -> Bool, failure: @escaping () -> Void) {
        self.send=send;self.failure=failure;self.connectedDevices=connectedDevices
        self.makeHaptics=makeHaptics;self.makeExtras=makeExtras;self.feedbackFailure=feedbackFailure
        let center=NotificationCenter.default
        for name in [NSNotification.Name.GCControllerDidConnect,NSNotification.Name.GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    isolated deinit {
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
            // Capture's releaseAll neutralizes states actually accepted by the worker.
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
        (haptics[slot]?.capabilities ?? []).union(extras[slot]?.capabilities ?? []).union(.analogTriggers)
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
                let kind: ControllerMotionKind = value.kind == .accelerometerRate ? .accelerometer : .gyroscope
                guard let extra=extras[slot],extra.capabilities.contains(kind == .accelerometer ? .accelerometer : .gyroscope) else { continue }
                extra.setMotion(kind,rateHz:value.first)
            }
            guard enabled else { return }
        }
    }
    private func applyMotors(_ value: ControllerFeedback,slot: Int) {
        guard let feedback=haptics[slot] else { return }
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
        _=emit(.controller(slot:UInt8(slot),activeMask:mask,state:Self.snapshot(pad)))
    }
    @discardableResult private func emit(_ event: RemoteInputEvent) -> Bool {
        if send(event) { return true }
        setEnabled(false);failure();return false
    }
    static func snapshot(_ pad: GCExtendedGamepad) -> ControllerState {
        var buttons: UInt32=0
        let mapping: [(GCControllerButtonInput?,UInt32)] = [
            (pad.dpad.up,0x1),(pad.dpad.down,0x2),(pad.dpad.left,0x4),(pad.dpad.right,0x8),
            (pad.buttonMenu,0x10),(pad.buttonOptions,0x20),
            (pad.leftThumbstickButton,0x40),(pad.rightThumbstickButton,0x80),
            (pad.leftShoulder,0x100),(pad.rightShoulder,0x200),
            (pad.buttonA,0x1000),(pad.buttonB,0x2000),(pad.buttonX,0x4000),(pad.buttonY,0x8000),
        ]
        for (button,flag) in mapping+extraButtons(pad) where button?.isPressed == true { buttons |= flag }
        let left=ControllerState.stick(x:pad.leftThumbstick.xAxis.value,y:pad.leftThumbstick.yAxis.value)
        let right=ControllerState.stick(x:pad.rightThumbstick.xAxis.value,y:pad.rightThumbstick.yAxis.value)
        return ControllerState(buttons:buttons,leftTrigger:ControllerState.trigger(pad.leftTrigger.value),
                               rightTrigger:ControllerState.trigger(pad.rightTrigger.value),
                               leftX:left.0,leftY:left.1,rightX:right.0,rightY:right.1)
    }
}
