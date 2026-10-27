/// Windows speaker-mask order, as used by Nightjar's negotiated Opus output mapping.
/// Surround channels are folded into stereo with fixed headroom; LFE is omitted.
public struct StereoMixMatrix: Sendable {
    public enum MixError: Error { case unsupportedLayout }
    public let channelCount: Int
    private let left: [Float]
    private let right: [Float]
    public init(channelCount: Int, channelMask: UInt16) throws {
        guard (1...8).contains(channelCount), channelMask.nonzeroBitCount == channelCount,
              channelMask & ~UInt16(0x073F) == 0 else { throw MixError.unsupportedLayout }
        self.channelCount = channelCount
        if channelCount == 1 { left = [1]; right = [1]; return }
        let rootHalf: Float = 0.70710678
        var l: [Float] = [], r: [Float] = []
        for bit in 0..<16 where channelMask & (1 << bit) != 0 {
            switch bit {
            case 0: l.append(1); r.append(0) // FL
            case 1: l.append(0); r.append(1) // FR
            case 2: l.append(rootHalf); r.append(rootHalf) // FC
            case 3: l.append(0); r.append(0) // LFE: no low-pass/crossover, so omit it.
            case 4, 9: l.append(rootHalf); r.append(0) // BL, SL
            case 5, 10: l.append(0); r.append(rootHalf) // BR, SR
            case 8: l.append(0.5); r.append(0.5) // BC
            default: throw MixError.unsupportedLayout
            }
        }
        let headroom = max(1, max(l.reduce(0,+),r.reduce(0,+)))
        left = l.map { $0/headroom }; right = r.map { $0/headroom }
    }
    /// Writes interleaved stereo into caller-owned storage; does not allocate.
    public func mix(_ input: UnsafeBufferPointer<Float>, frames: Int, into output: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard frames >= 0, frames <= input.count/channelCount, frames <= output.count/2 else { return false }
        for frame in 0..<frames {
            var l: Float = 0, r: Float = 0
            for ch in 0..<channelCount {
                let sample = input[frame*channelCount+ch]
                guard sample.isFinite else { return false }
                l += sample*left[ch]; r += sample*right[ch]
            }
            output[frame*2] = min(1,max(-1,l)); output[frame*2+1] = min(1,max(-1,r))
        }
        return true
    }
}
