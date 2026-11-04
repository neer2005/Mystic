import AVFoundation
import AudioToolbox
import CoreAudio
import MysticCore

/// Only named 5.1/7.1 speaker configurations qualify for discrete playback.
/// An eight-channel interface with unknown assignments is not presumed to be 7.1.
struct AudioSpeakerLayout {
    let layout: AVAudioChannelLayout
    let speakers: [AudioSpeaker]
    init?(_ layout: AVAudioChannelLayout) {
        guard let labels=Self.labels(layout),[6,8].contains(labels.count) else { return nil }
        let hasDirect=labels.contains(kAudioChannelLabel_LeftSurroundDirect) && labels.contains(kAudioChannelLabel_RightSurroundDirect)
        var speakers: [AudioSpeaker] = []
        for label in labels {
            switch label {
            case kAudioChannelLabel_Left: speakers.append(.left)
            case kAudioChannelLabel_Right: speakers.append(.right)
            case kAudioChannelLabel_Center: speakers.append(.center)
            case kAudioChannelLabel_LFEScreen: speakers.append(.lfe)
            // Windows-style 7.1 bitmaps name rear channels Ls/Rs and side channels Lsd/Rsd.
            // MPEG 7.1 C instead uses Ls/Rs for sides and explicit RearSurround labels.
            case kAudioChannelLabel_LeftSurround: speakers.append(hasDirect && labels.count == 8 ? .rearLeft : .surroundLeft)
            case kAudioChannelLabel_RightSurround: speakers.append(hasDirect && labels.count == 8 ? .rearRight : .surroundRight)
            case kAudioChannelLabel_LeftSurroundDirect: speakers.append(.surroundLeft)
            case kAudioChannelLabel_RightSurroundDirect: speakers.append(.surroundRight)
            case kAudioChannelLabel_RearSurroundLeft: speakers.append(.rearLeft)
            case kAudioChannelLabel_RearSurroundRight: speakers.append(.rearRight)
            default: return nil
            }
        }
        guard Set(speakers).count == speakers.count else { return nil }
        self.layout=layout;self.speakers=speakers
    }
    #if os(macOS)
    /// The speaker layout set for a Mac output device in Audio MIDI Setup.
    static func device(_ id: AudioDeviceID,channels: AVAudioChannelCount) -> Self? {
        guard [6,8].contains(channels) else { return nil }
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyPreferredChannelLayout,
            mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        var size: UInt32=0
        guard AudioObjectGetPropertyDataSize(id,&address,0,nil,&size) == noErr,
              size >= headerSize,size <= 65_536 else { return nil }
        let storage=UnsafeMutableRawPointer.allocate(byteCount:max(Int(size),MemoryLayout<AudioChannelLayout>.size),alignment:MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as:UInt8.self,repeating:0,count:max(Int(size),MemoryLayout<AudioChannelLayout>.size))
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,storage) == noErr else { return nil }
        let pointer=storage.assumingMemoryBound(to:AudioChannelLayout.self)
        let count=pointer.pointee.mNumberChannelDescriptions
        guard count <= 8,Int(size) >= Int(headerSize)+Int(count)*MemoryLayout<AudioChannelDescription>.size else { return nil }
        let value=AVAudioChannelLayout(layout:pointer)
        guard value.channelCount == channels else { return nil }
        return Self(value)
    }
    #endif
    static func configured(_ speakers: [AudioSpeaker]) -> Self? {
        guard [6,8].contains(speakers.count) else { return nil }
        let size=Int(headerSize)+speakers.count*MemoryLayout<AudioChannelDescription>.size
        let storage=UnsafeMutableRawPointer.allocate(byteCount:size,alignment:MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as:UInt8.self,repeating:0,count:size)
        let pointer=storage.assumingMemoryBound(to:AudioChannelLayout.self)
        pointer.pointee.mChannelLayoutTag=kAudioChannelLayoutTag_UseChannelDescriptions
        pointer.pointee.mNumberChannelDescriptions=UInt32(speakers.count)
        let descriptions=storage.advanced(by:Int(headerSize)).assumingMemoryBound(to:AudioChannelDescription.self)
        for (index,speaker) in speakers.enumerated() {
            let label: AudioChannelLabel
            switch speaker {
            case .left: label=kAudioChannelLabel_Left
            case .right: label=kAudioChannelLabel_Right
            case .center: label=kAudioChannelLabel_Center
            case .lfe: label=kAudioChannelLabel_LFEScreen
            case .surroundLeft: label=kAudioChannelLabel_LeftSurround
            case .surroundRight: label=kAudioChannelLabel_RightSurround
            case .rearLeft: label=kAudioChannelLabel_RearSurroundLeft
            case .rearRight: label=kAudioChannelLabel_RearSurroundRight
            }
            descriptions[index].mChannelLabel=label
        }
        return Self(AVAudioChannelLayout(layout:pointer))
    }
    private static let headerSize=UInt32(MemoryLayout<AudioChannelLayout>.offset(of:\.mChannelDescriptions)!)
    private static func labels(_ layout: AVAudioChannelLayout) -> [AudioChannelLabel]? {
        labels(layout.layout,depth:0)
    }
    private static func labels(_ pointer: UnsafePointer<AudioChannelLayout>,depth: Int) -> [AudioChannelLabel]? {
        guard depth < 3 else { return nil }
        let value=pointer.pointee
        // ChannelLayoutForTag preserves the tag while populating explicit descriptions.
        if value.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions || value.mNumberChannelDescriptions > 0 {
            guard [6,8].contains(value.mNumberChannelDescriptions) else { return nil }
            let descriptions=UnsafeRawPointer(pointer).advanced(by:Int(headerSize)).assumingMemoryBound(to:AudioChannelDescription.self)
            return (0..<Int(value.mNumberChannelDescriptions)).map { descriptions[$0].mChannelLabel }
        }
        let property: AudioFormatPropertyID
        var specifier: UInt32
        if value.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap {
            property=kAudioFormatProperty_ChannelLayoutForBitmap;specifier=value.mChannelBitmap.rawValue
        } else { property=kAudioFormatProperty_ChannelLayoutForTag;specifier=value.mChannelLayoutTag }
        var size: UInt32=0
        guard AudioFormatGetPropertyInfo(property,4,&specifier,&size) == noErr,
              size >= headerSize,size <= 65_536 else { return nil }
        let storage=UnsafeMutableRawPointer.allocate(byteCount:max(Int(size),MemoryLayout<AudioChannelLayout>.size),alignment:MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as:UInt8.self,repeating:0,count:max(Int(size),MemoryLayout<AudioChannelLayout>.size))
        guard AudioFormatGetProperty(property,4,&specifier,&size,storage) == noErr else { return nil }
        let pointer=storage.assumingMemoryBound(to:AudioChannelLayout.self)
        let count=pointer.pointee.mNumberChannelDescriptions
        guard count <= 8,size >= headerSize+count*UInt32(MemoryLayout<AudioChannelDescription>.size) else { return nil }
        // Parse raw descriptions without normalizing them back to a compact layout.
        return labels(pointer,depth:depth+1)
    }
}
