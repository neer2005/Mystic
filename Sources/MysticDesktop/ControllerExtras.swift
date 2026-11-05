import Foundation
import GameController
import MysticCore

/// A controller's light, motion sensors and battery, beside its buttons and motors.
@ControllerActor
protocol ControllerExtras: AnyObject {
    /// Some of accelerometer, gyroscope, battery and light; never analog triggers or motors.
    var capabilities: ControllerCapabilities { get }
    /// Starts battery reports; motion is reported only while the host asks for it.
    func start(motion: @escaping (ControllerMotionKind,Float,Float,Float) -> Void,battery: @escaping (ControllerBattery) -> Void)
    func setLight(red: UInt8,green: UInt8,blue: UInt8)
    /// The host's report rate for one sensor; zero stops it.
    func setMotion(_ kind: ControllerMotionKind,rateHz: UInt16)
    func stop()
}

/// GameController's light, GCMotion and battery. Motion is converted to Moonlight's units
/// (m/s² with gravity as an upward reaction, degrees per second) in GameController's axes;
/// whether those match the host's pad axes is unverified until a physical playtest.
@ControllerActor
final class NativeControllerExtras: ControllerExtras {
    private let controller: GCController
    let capabilities: ControllerCapabilities
    private var rates: [ControllerMotionKind:TimeInterval] = [:]
    private var lastSent: [ControllerMotionKind:TimeInterval] = [:]
    private var motion: ((ControllerMotionKind,Float,Float,Float) -> Void)?
    private var battery: ((ControllerBattery) -> Void)?
    private var lastBattery: ControllerBattery?
    private var batteryTimer: (any DispatchSourceTimer)?
    private var restoredGestures: [(GCControllerElement,GCControllerElement.SystemGestureState)] = []
    private var stopped=false

    static func capabilities(of controller: GCController) -> ControllerCapabilities {
        var caps: ControllerCapabilities=[]
        if let motion=controller.motion {
            caps.insert(.accelerometer)
            if motion.hasRotationRate { caps.insert(.gyroscope) }
        }
        if controller.battery != nil { caps.insert(.battery) }
        if controller.light != nil { caps.insert(.light) }
        return caps
    }
    init(controller: GCController) {
        self.controller=controller
        capabilities=Self.capabilities(of:controller)
        // Guide and Share reach the host instead of opening the Mac's own overlays.
        var elements: [GCControllerElement?]=[controller.extendedGamepad?.buttonHome]
        if let xbox=controller.extendedGamepad as? GCXboxGamepad { elements.append(xbox.buttonShare) }
        for case let element? in elements {
            restoredGestures.append((element,element.preferredSystemGestureState))
            element.preferredSystemGestureState = .disabled
        }
    }
    /// Called again after every re-announcement, which the host takes as a fresh controller:
    /// the battery is reported anew and the one timer replaced.
    func start(motion: @escaping (ControllerMotionKind,Float,Float,Float) -> Void,battery: @escaping (ControllerBattery) -> Void) {
        guard !stopped else { return }
        self.motion=motion;self.battery=battery
        batteryTimer?.cancel();batteryTimer=nil;lastBattery=nil
        guard capabilities.contains(.battery) else { return }
        reportBattery()
        let timer=DispatchSource.makeTimerSource(queue:ControllerActor.queue)
        timer.schedule(deadline:.now()+5,repeating:5,leeway:.seconds(1))
        timer.setEventHandler { [weak self] in ControllerActor.assumeIsolated { self?.reportBattery() } }
        timer.resume();batteryTimer=timer
    }
    private func reportBattery() {
        guard !stopped,let device=controller.battery else { return }
        let state: ControllerBattery.State = switch device.batteryState {
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        let report=ControllerBattery(state:state,level:device.batteryLevel)
        guard report != lastBattery else { return }
        lastBattery=report;battery?(report)
    }
    func setLight(red: UInt8,green: UInt8,blue: UInt8) {
        guard !stopped,let light=controller.light else { return }
        light.color=GCColor(red:Float(red)/255,green:Float(green)/255,blue:Float(blue)/255)
    }
    func setMotion(_ kind: ControllerMotionKind,rateHz: UInt16) {
        guard !stopped,let device=controller.motion,capabilities.contains(kind == .accelerometer ? .accelerometer : .gyroscope) else { return }
        if rateHz == 0 { rates.removeValue(forKey:kind) } else { rates[kind]=1/Double(rateHz) }
        let active = !rates.isEmpty
        if device.sensorsRequireManualActivation { device.sensorsActive=active }
        device.valueChangedHandler = active ? { [weak self] motion in
            ControllerActor.assumeIsolated { self?.report(motion) }
        } : nil
    }
    private func report(_ device: GCMotion) {
        guard !stopped,let motion else { return }
        let now=ProcessInfo.processInfo.systemUptime
        func due(_ kind: ControllerMotionKind) -> Bool {
            guard let interval=rates[kind] else { return false }
            // A little early is fine: the host's rate is a ceiling, not a clock.
            guard now-(lastSent[kind] ?? 0) >= interval*0.9 else { return false }
            lastSent[kind]=now;return true
        }
        if due(.accelerometer) {
            let a=device.acceleration,g=9.80665
            motion(.accelerometer,Float(-a.x*g),Float(-a.y*g),Float(-a.z*g))
        }
        if device.hasRotationRate,due(.gyroscope) {
            let r=device.rotationRate,degrees=180/Double.pi
            motion(.gyroscope,Float(r.x*degrees),Float(r.y*degrees),Float(r.z*degrees))
        }
    }
    func stop() {
        guard !stopped else { return };stopped=true
        batteryTimer?.cancel();batteryTimer=nil
        if let device=controller.motion {
            device.valueChangedHandler=nil
            if device.sensorsRequireManualActivation { device.sensorsActive=false }
        }
        for (element,state) in restoredGestures { element.preferredSystemGestureState=state }
        restoredGestures.removeAll();motion=nil;battery=nil;rates.removeAll()
    }
    isolated deinit { stop() }
}
