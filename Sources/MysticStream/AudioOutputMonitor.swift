import Foundation

struct AudioOutputDevice: Equatable, Sendable {
    /// The Core Audio device on macOS; 0 on iOS, where the system owns the route.
    let id: UInt32
    let name: String
}

/// Owner calls lifecycle methods on its serial control queue. Listener blocks only signal changes.
protocol AudioOutputMonitoring: AnyObject, Sendable {
    func start(changed: @escaping @Sendable () -> Void) throws
    func refresh() throws
    func stop()
}

#if os(macOS)
import CoreAudio

/// The Mac's default output device through the Core Audio HAL, which iOS does not have.

final class AudioOutputMonitor: AudioOutputMonitoring, @unchecked Sendable {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private let callbacks=DispatchQueue(label:"Mystic.AudioDeviceNotifications")
    private var system: [Registration] = [],device: [Registration] = []
    private var observedDevice: AudioDeviceID = kAudioObjectUnknown
    private var changed: (@Sendable () -> Void)?
    func start(changed: @escaping @Sendable () -> Void) throws {
        stop();self.changed=changed
        do {
            for selector in [kAudioHardwarePropertyDefaultOutputDevice,kAudioHardwarePropertyDevices] {
                system.append(try register(object:AudioObjectID(kAudioObjectSystemObject),selector:selector,changed:changed))
            }
            try refresh()
        } catch { stop();throw error }
    }
    func refresh() throws {
        guard let changed else { return }
        let id=try Self.defaultDeviceID()
        guard id != observedDevice else { return }
        remove(&device);observedDevice=kAudioObjectUnknown
        guard id != kAudioObjectUnknown else { return }
        do {
            for selector in [kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyNominalSampleRate] {
                device.append(try register(object:id,selector:selector,changed:changed))
            }
            device.append(try register(object:id,selector:kAudioDevicePropertyStreamConfiguration,
                scope:kAudioDevicePropertyScopeOutput,changed:changed))
            var speakers=Self.address(kAudioDevicePropertyPreferredChannelLayout,scope:kAudioDevicePropertyScopeOutput)
            if AudioObjectHasProperty(id,&speakers),let registration=try? register(object:id,selector:kAudioDevicePropertyPreferredChannelLayout,
                scope:kAudioDevicePropertyScopeOutput,changed:changed) {
                // An optional speaker-layout listener must not disable device/route monitoring.
                device.append(registration)
            }
            observedDevice=id
        } catch { remove(&device);throw error }
    }
    func stop() { remove(&system);remove(&device);observedDevice=kAudioObjectUnknown;changed=nil }
    deinit { stop() }
    private func register(object: AudioObjectID,selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          changed: @escaping @Sendable () -> Void) throws -> Registration {
        var address=Self.address(selector,scope:scope)
        let block: AudioObjectPropertyListenerBlock = { _,_ in changed() }
        let status=AudioObjectAddPropertyListenerBlock(object,&address,callbacks,block)
        guard status == noErr else { throw AudioPlaybackError("Cannot monitor audio output changes (\(status)).") }
        return Registration(object:object,address:address,block:block)
    }
    private func remove(_ registrations: inout [Registration]) {
        for var item in registrations {
            AudioObjectRemovePropertyListenerBlock(item.object,&item.address,callbacks,item.block)
        }
        registrations.removeAll()
    }
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    private static func defaultDeviceID() throws -> AudioDeviceID {
        var address=address(kAudioHardwarePropertyDefaultOutputDevice)
        var id=AudioDeviceID(kAudioObjectUnknown),size=UInt32(MemoryLayout<AudioDeviceID>.size)
        let status=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&id)
        guard status == noErr else { throw AudioPlaybackError("Cannot read the default audio output (\(status)).") }
        return id
    }
    static func requireAvailableOutput() throws {
        let id=try defaultDeviceID()
        guard id != kAudioObjectUnknown else { throw AudioPlaybackError("No default audio output is connected.") }
        var address=address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,&alive) == noErr,alive != 0 else {
            throw AudioPlaybackError("The default audio output is unavailable.")
        }
    }
    /// The device's I/O buffer size in its own frames, as it reads from Mystic at once.
    static func bufferFrames(_ id: AudioDeviceID) -> Int? {
        guard id != kAudioObjectUnknown else { return nil }
        var address=address(kAudioDevicePropertyBufferFrameSize,scope:kAudioObjectPropertyScopeOutput)
        var frames: UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,&frames) == noErr,(1...16384).contains(frames) else { return nil }
        return Int(frames)
    }
    /// Asks `id` to read Mystic's audio `seconds` at a time and returns the frames it settled on.
    /// macOS keeps this per process, so other apps playing on the same device keep their own
    /// buffer, and it lapses when Mystic stops using the device. The playout's lead is 10 ms plus
    /// one read (`AudioPlayout.lead`), so macOS's usual 512 frames held about 11 ms of that.
    @discardableResult
    static func requestBufferDuration(_ seconds: Double,on id: AudioDeviceID) -> Int? {
        guard id != kAudioObjectUnknown else { return nil }
        var rateAddress=address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64=0,rateSize=UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id,&rateAddress,0,nil,&rateSize,&rate) == noErr,rate > 0 else { return nil }
        var rangeAddress=address(kAudioDevicePropertyBufferFrameSizeRange,scope:kAudioObjectPropertyScopeOutput)
        var range=AudioValueRange(),rangeSize=UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id,&rangeAddress,0,nil,&rangeSize,&range) == noErr else { return nil }
        var frames=UInt32(bufferFrames(seconds:seconds,sampleRate:rate,range:range.mMinimum...range.mMaximum))
        var sizeAddress=address(kAudioDevicePropertyBufferFrameSize,scope:kAudioObjectPropertyScopeOutput)
        guard AudioObjectSetPropertyData(id,&sizeAddress,0,nil,UInt32(MemoryLayout<UInt32>.size),&frames) == noErr else { return nil }
        return bufferFrames(id)
    }
    /// `seconds` at `sampleRate`, within what the device allows.
    static func bufferFrames(seconds: Double,sampleRate: Double,range: ClosedRange<Double>) -> Int {
        Int(min(max((seconds*sampleRate).rounded(),range.lowerBound),range.upperBound))
    }
    static func describe(_ id: AudioDeviceID) -> AudioOutputDevice? {
        guard id != kAudioObjectUnknown else { return nil }
        var address=address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size=UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,&name) == noErr else {
            return AudioOutputDevice(id:id,name:"Audio output")
        }
        return AudioOutputDevice(id:id,name:name?.takeRetainedValue() as String? ?? "Audio output")
    }
}
#endif
