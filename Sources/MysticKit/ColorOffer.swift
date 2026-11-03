import Foundation
import CMystic

/// What became of "10-bit Color (SDR)" for a launch: Nightjar's `color::offer`.
public struct TenBitOffer: Decodable, Sendable, Equatable {
    public let formats: UInt32
    public let offered: Bool
    /// Why it is not offered, when that is worth saying.
    public let refusal: String?
    private struct Envelope: Decodable { let value: TenBitOffer? }
    public static func make(base: UInt32,decodable: UInt32,hostCodecs: UInt32,hdr: Bool,wanted: Bool,decoderReason: String) -> TenBitOffer {
        let fallback=TenBitOffer(formats:base,offered:false,refusal:nil)
        guard let pointer=mystic_sdr10_offer(base,decodable,hostCodecs,hdr,wanted,decoderReason) else { return fallback }
        defer { mystic_string_free(pointer) }
        return (try? JSONDecoder().decode(Envelope.self,from:Data(bytes:pointer,count:strlen(pointer))))?.value ?? fallback
    }
    private init(formats: UInt32,offered: Bool,refusal: String?) { self.formats=formats;self.offered=offered;self.refusal=refusal }
}
