import Foundation
import GameController
import MysticCore

/// Handlers live on the main queue alongside capture focus. Extended profiles provide
/// positional face buttons for both Xbox and PlayStation controllers.
@MainActor
final class StreamControllers {
    private var devices: [Int:GCController] = [:]
    private let connectedDevices: () -> [GCController]
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private var haptics: [Int:any ControllerHaptics] = [:]
    private let makeHaptics: (GCController) -> (any ControllerHaptics)?
    private let feedbackFailure: (String) -> Void
    private(set) var feedbackEpoch: UInt64 = 0
    private let send: (RemoteInputEvent) -> Bool
    private let failure: () -> Void
    init(connectedDevices: @escaping () -> [GCController] = { GCController.controllers() },
         makeHaptics: @escaping (GCController) -> (any ControllerHaptics)? = { NativeControllerHaptics(controller:$0) },
         feedbackFailure: @escaping (String) -> Void = { _ in },
         send: @escaping (RemoteInputEvent) -> Bool, failure: @escaping () -> Void) {
        self.send=send;self.failure=failure;self.connectedDevices=connectedDevices
        self.makeHaptics=makeHaptics;self.feedbackFailure=feedbackFailure
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
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled=value;feedbackEpoch &+= 1
        if value { refresh() }
        else {
            for controller in devices.values { controller.extendedGamepad?.valueChangedHandler=nil }
            for feedback in haptics.values { feedback.stop() };haptics.removeAll()
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
            devices.removeValue(forKey:slot);changed=true
            guard emit(.controller(slot:UInt8(slot),activeMask:mask,state:ControllerState())) else { return }
        }
        for device in connected where !devices.values.contains(where: { $0 === device }) {
            guard let slot=(0..<4).first(where: { devices[$0] == nil }) else { break }
            devices[slot]=device;haptics[slot]=makeHaptics(device);changed=true
        }
        guard changed else { return }
        feedbackEpoch &+= 1
        for slot in devices.keys.sorted() {
            guard enabled,let device=devices[slot] else { return }
            device.handlerQueue = .main
            guard emit(.controllerArrival(slot:UInt8(slot),activeMask:mask,capabilities:capabilities(slot:slot),feedbackEpoch:feedbackEpoch)) else { return }
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
        (haptics[slot]?.capabilities ?? []).union(.analogTriggers)
    }
    func applyFeedback(_ values: [ControllerFeedback],epoch: UInt64) {
        guard enabled,epoch == feedbackEpoch else { return }
        for value in values {
            let slot=Int(value.slot)
            guard value.epoch == feedbackEpoch,devices[slot] != nil,let feedback=haptics[slot] else { continue }
            let required: ControllerCapabilities=value.kind == .rumble ? .rumble : .triggerRumble
            guard feedback.capabilities.contains(required) else { continue }
            do { try feedback.apply(value) }
            catch {
                feedback.stop();haptics.removeValue(forKey:slot)
                feedbackFailure("Controller feedback unavailable. Controller input remains active.")
                guard emit(.controllerArrival(slot:value.slot,activeMask:mask,capabilities:.analogTriggers,feedbackEpoch:feedbackEpoch)) else { return }
            }
        }
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
        for (button,flag) in mapping where button?.isPressed == true { buttons |= flag }
        let left=ControllerState.stick(x:pad.leftThumbstick.xAxis.value,y:pad.leftThumbstick.yAxis.value)
        let right=ControllerState.stick(x:pad.rightThumbstick.xAxis.value,y:pad.rightThumbstick.yAxis.value)
        return ControllerState(buttons:buttons,leftTrigger:ControllerState.trigger(pad.leftTrigger.value),
                               rightTrigger:ControllerState.trigger(pad.rightTrigger.value),
                               leftX:left.0,leftY:left.1,rightX:right.0,rightY:right.1)
    }
}
