import Foundation
import GameController
import CoreHaptics
import MysticCore

@MainActor
protocol ControllerHaptics: AnyObject {
    var capabilities: ControllerCapabilities { get }
    func apply(_ feedback: ControllerFeedback) throws
    func stop()
}

/// Only controller-created engines are used; the Mac's own haptic device is never a fallback.
@MainActor
final class NativeControllerHaptics: ControllerHaptics {
    private let low: Motor?
    private let high: Motor?
    private let combined: Motor?
    private let leftTrigger: Motor?
    private let rightTrigger: Motor?
    let capabilities: ControllerCapabilities

    init?(controller: GCController) {
        guard let haptics=controller.haptics else { return nil }
        func motor(_ locality: GCHapticsLocality,sharpness: Float) -> Motor? {
            guard haptics.supportedLocalities.contains(locality),
                  let engine=haptics.createEngine(withLocality:locality) else { return nil }
            return Motor(engine:engine,sharpness:sharpness)
        }
        let left=motor(.leftHandle,sharpness:0),right=motor(.rightHandle,sharpness:1)
        if let left,let right { low=left;high=right;combined=nil }
        else { low=nil;high=nil;combined=motor(.default,sharpness:0.5) }
        let lt=motor(.leftTrigger,sharpness:0.5),rt=motor(.rightTrigger,sharpness:0.5)
        if let lt,let rt { leftTrigger=lt;rightTrigger=rt }
        else { leftTrigger=nil;rightTrigger=nil }
        var caps: ControllerCapabilities=[]
        if combined != nil || (low != nil && high != nil) { caps.insert(.rumble) }
        if leftTrigger != nil && rightTrigger != nil { caps.insert(.triggerRumble) }
        capabilities=caps
        if caps.isEmpty { return nil }
    }
    func apply(_ feedback: ControllerFeedback) throws {
        let first=Float(feedback.first)/Float(UInt16.max),second=Float(feedback.second)/Float(UInt16.max)
        switch feedback.kind {
        case .rumble:
            if let combined { try combined.set(max(first,second)) }
            else { try low?.set(first);try high?.set(second) }
        case .triggerRumble:
            try leftTrigger?.set(first);try rightTrigger?.set(second)
        }
    }
    static func pattern(intensity: Float,sharpness: Float) throws -> CHHapticPattern {
        let event=CHHapticEvent(eventType:.hapticContinuous,parameters:[
            CHHapticEventParameter(parameterID:.hapticIntensity,value:1),
            CHHapticEventParameter(parameterID:.hapticSharpness,value:sharpness),
        ],relativeTime:0,duration:Double(GCHapticDurationInfinite))
        return try CHHapticPattern(events:[event],parameters:[
            CHHapticDynamicParameter(parameterID:.hapticIntensityControl,value:intensity,relativeTime:0),
        ])
    }
    func stop() {
        for motor in [low,high,combined,leftTrigger,rightTrigger] { motor?.stop() }
    }
    isolated deinit { stop() }
}

/// Reuses a continuous player while a motor is active. Zero stops the pattern immediately.
@MainActor
private final class Motor {
    private let engine: CHHapticEngine
    private let sharpness: Float
    private var player: (any CHHapticPatternPlayer)?
    private var closed=false
    private let revision=HapticsEngineRevision()
    private var seenRevision: UInt64=0
    init(engine: CHHapticEngine,sharpness: Float) {
        self.engine=engine;self.sharpness=sharpness
        let revision=revision
        engine.resetHandler={ revision.invalidate() }
        engine.stoppedHandler={ _ in revision.invalidate() }
    }
    func set(_ intensity: Float) throws {
        guard !closed else { return }
        discardInvalidatedPlayer()
        if intensity == 0 {
            try player?.stop(atTime:CHHapticTimeImmediate);player=nil;return
        }
        try engine.start()
        discardInvalidatedPlayer()
        if player == nil {
            let pattern=try NativeControllerHaptics.pattern(intensity:intensity,sharpness:sharpness)
            let next=try engine.makePlayer(with:pattern)
            try next.start(atTime:CHHapticTimeImmediate)
            player=next
        } else {
            try player?.sendParameters([CHHapticDynamicParameter(parameterID:.hapticIntensityControl,value:intensity,relativeTime:0)],atTime:CHHapticTimeImmediate)
        }
    }
    private func discardInvalidatedPlayer() {
        let current=revision.value
        guard current != seenRevision else { return }
        // A late stop/reset notification can follow a restart; never orphan a playing pattern.
        try? player?.stop(atTime:CHHapticTimeImmediate)
        player=nil;seenRevision=current
    }
    func stop() {
        guard !closed else { return };closed=true
        try? player?.stop(atTime:CHHapticTimeImmediate);player=nil
        engine.resetHandler={};engine.stoppedHandler={ _ in }
        engine.stop(completionHandler:nil)
    }
    isolated deinit { stop() }
}

/// Core Haptics invokes reset/stop handlers off the actor; never enqueue a stale player reset.
private final class HapticsEngineRevision: @unchecked Sendable {
    private let lock=NSLock()
    private var counter: UInt64=0
    var value: UInt64 { lock.withLock { counter } }
    func invalidate() { lock.withLock { counter &+= 1 } }
}
