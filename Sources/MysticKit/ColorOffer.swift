import Foundation
import CMystic

/// What became of "Prefer YUV 4:4:4" and "10-bit Color (SDR)" for a launch: Nightjar's `color::offer`.
public struct ColorOffer: Decodable, Sendable, Equatable {
    public let formats: UInt32
    public let yuv444: Bool,sdr10: Bool
    /// Why each is not offered, when that is worth saying.
    public let yuv444Refusal: String?,sdr10Refusal: String?
    private struct Envelope: Decodable { let value: ColorOffer? }
    public static func make(base: UInt32,decodable: UInt32,hostCodecs: UInt32,hdr: Bool,yuv444: Bool,sdr10: Bool,decoderReason: String) -> ColorOffer {
        let fallback=ColorOffer(formats:base,yuv444:false,sdr10:false,yuv444Refusal:nil,sdr10Refusal:nil)
        guard let pointer=mystic_color_offer(base,decodable,hostCodecs,hdr,yuv444,sdr10,decoderReason) else { return fallback }
        defer { mystic_string_free(pointer) }
        return (try? JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer))))?.value ?? fallback
    }
    private init(formats: UInt32,yuv444: Bool,sdr10: Bool,yuv444Refusal: String?,sdr10Refusal: String?) {
        self.formats=formats;self.yuv444=yuv444;self.sdr10=sdr10;self.yuv444Refusal=yuv444Refusal;self.sdr10Refusal=sdr10Refusal
    }
}
