/// Speaker roles are independent of codec order and physical output channel order.
public enum AudioSpeaker: String, Sendable, CaseIterable, Hashable {
    case left,right,center,lfe,surroundLeft,surroundRight,rearLeft,rearRight
}

public struct AudioChannelRouting: Sendable {
    public let inputChannels: Int
    public let channelMask: UInt16
    public let outputChannels: Int
    public let isDiscrete: Bool
    public let fallbackReason: String?
    private let mapping: [Int?]
    private let stereo: StereoMixMatrix
    public init(channelCount: Int,channelMask: UInt16,destination: [AudioSpeaker]? = nil,fallbackReason: String? = nil) throws {
        inputChannels=channelCount;self.channelMask=channelMask
        stereo=try StereoMixMatrix(channelCount:channelCount,channelMask:channelMask)
        var source: [AudioSpeaker]?
        switch (channelCount,channelMask) {
        case (6,0x3F),(6,0x60F): source=[.left,.right,.center,.lfe,.surroundLeft,.surroundRight]
        case (8,0x63F): source=[.left,.right,.center,.lfe,.rearLeft,.rearRight,.surroundLeft,.surroundRight]
        default: source=nil
        }
        if channelCount == 6,source != nil,let destination,!destination.contains(.surroundLeft),!destination.contains(.surroundRight),
           destination.contains(.rearLeft),destination.contains(.rearRight) {
            source=[.left,.right,.center,.lfe,.rearLeft,.rearRight]
        }
        if let source,let destination,[6,8].contains(destination.count),
           Set(destination).count == destination.count,source.allSatisfy(destination.contains) {
            outputChannels=destination.count;isDiscrete=true;self.fallbackReason=nil
            mapping=destination.map { source.firstIndex(of:$0) }
        } else {
            outputChannels=2;isDiscrete=false;mapping=[]
            self.fallbackReason=channelCount <= 2 ? nil : (fallbackReason ?? (destination == nil ? "Output speaker layout unavailable" : "Output lacks the required surround speakers"))
        }
    }
    public var label: String {
        if isDiscrete { return "\(inputChannels == 6 ? "5.1" : "7.1") discrete\(outputChannels != inputChannels ? " (\(outputChannels)-channel output)" : "")" }
        return inputChannels <= 2 ? "Stereo" : "\(inputChannels == 6 ? "5.1" : (inputChannels == 8 ? "7.1" : "\(inputChannels)-channel")) → stereo"
    }
    /// Producer-side only; output order matches the destination's channel descriptions.
    public func route(_ input: UnsafeBufferPointer<Float>,frames: Int,into output: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard frames >= 0,frames <= input.count/inputChannels,frames <= output.count/outputChannels else { return false }
        if !isDiscrete { return stereo.mix(input,frames:frames,into:output) }
        for frame in 0..<frames {
            for channel in 0..<outputChannels {
                let sample=mapping[channel].map { input[frame*inputChannels+$0] } ?? 0
                guard sample.isFinite else { return false }
                output[frame*outputChannels+channel]=sample
            }
        }
        return true
    }
}
