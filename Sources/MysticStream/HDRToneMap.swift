import Foundation

/// The Metal renderer's own tone map for PQ (HDR10) video. Handing macOS the stream's HDR10
/// metadata (`CAMetalLayer.edrMetadata`) makes it tone map in the compositor, and the Metal HUD
/// then reads Composited in full screen; without the metadata the same 10-bit PQ layer reads
/// Direct (probed on an M1 Max, 2026-11-05). So the shader does what the metadata asked of macOS:
/// it rolls the picture's highlights off below what the screen can show right now, and macOS
/// shows the PQ values as they are.
///
/// Brightness follows Apple's EDR convention ("Using system tone mapping on video content"): an
/// EDR value of 1.0 is 100 nits, and EDR content is clamped at the screen's current
/// `maximumExtendedDynamicRangeColorComponentValue`. The screen can therefore show
/// `headroom × 100` nits now. If macOS in fact places PQ white higher, the roll-off only starts
/// a little early; nothing clips.
///
/// The curve is ITU-R BT.2390's EETF, which works on PQ code values directly, applied to each of
/// R′G′B′ as BT.2390 allows: a straight line up to a knee, then a Hermite spline that lands the
/// source's peak on the screen's. Content already within the screen's range passes untouched.
public struct HDRToneMap: Equatable, Sendable {
    /// The source's peak and the screen's, as PQ code values in 0...1.
    public let sourcePeak: Float,displayPeak: Float
    /// Whether the shader rolls highlights off; false when the screen shows the source's peak.
    public var active: Bool { displayPeak < sourcePeak }

    /// What a stream without mastering or light-level metadata is taken to reach: HDR10's usual
    /// mastering peak, and what Windows' HDR desktop is calibrated to by default.
    public static let defaultSourceNits=1000.0
    /// Nits per EDR value of 1.0 (Apple's `opticalOutputScale` of 100).
    public static let nitsPerEDRUnit=100.0

    public init(sourceNits: Double,headroom: Double) {
        let source=min(10000,max(Self.nitsPerEDRUnit,sourceNits.isFinite ? sourceNits : Self.defaultSourceNits))
        let display=min(source,Self.nitsPerEDRUnit*max(1,headroom.isFinite ? headroom : 1))
        sourcePeak=Float(Self.pq(nits:source));displayPeak=Float(Self.pq(nits:display))
    }

    /// The source's peak from its SEI metadata, CoreVideo's big-endian layout: MaxCLL (content
    /// light level, nits) when the encoder measured it, else the mastering display's maximum
    /// luminance (0.0001 nits), else `defaultSourceNits`.
    public static func sourceNits(masteringDisplay: Data?,contentLightLevel: Data?) -> Double {
        if let light=contentLightLevel,light.count >= 4 {
            let maxCLL=Double(UInt16(light[light.startIndex]) << 8 | UInt16(light[light.startIndex+1]))
            if maxCLL > 0 { return maxCLL }
        }
        if let mastering=masteringDisplay,mastering.count >= 24 {
            let bytes=Array(mastering)
            let raw=UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19])
            if raw > 0 { return Double(raw)/10000 }
        }
        return defaultSourceNits
    }

    /// SMPTE ST 2084 inverse EOTF: absolute nits to a PQ code value.
    public static func pq(nits: Double) -> Double {
        let m1=2610.0/16384,m2=2523.0/4096*128,c1=3424.0/4096,c2=2413.0/4096*32,c3=2392.0/4096*32
        let y=pow(min(1,max(0,nits/10000)),m1)
        return pow((c1+c2*y)/(1+c3*y),m2)
    }

    /// BT.2390's EETF for one PQ component, the same arithmetic as `videoFragment`'s; the CPU
    /// copy is what the tests check.
    public func map(_ value: Float) -> Float {
        guard active,sourcePeak > 0 else { return value }
        let e1=min(1,max(0,value/sourcePeak)),maxLum=displayPeak/sourcePeak
        let knee=max(0,1.5*maxLum-0.5)
        guard e1 > knee else { return e1*sourcePeak }
        let t=(e1-knee)/(1-knee),t2=t*t,t3=t2*t
        let e2=(2*t3-3*t2+1)*knee+(t3-2*t2+t)*(1-knee)+(-2*t3+3*t2)*maxLum
        return min(displayPeak,e2*sourcePeak)
    }
}
