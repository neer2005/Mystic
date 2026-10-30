import Foundation
import CoreVideo
import Observation

/// Reports source tags and the destination screen separately; neither is a luminance measurement.
@MainActor @Observable
public final class VideoOutputState {
    public private(set) var transfer = "Waiting for video"
    public private(set) var colorPrimaries = "Unspecified"
    public private(set) var hasMasteringMetadata = false
    public private(set) var hasContentLightMetadata = false
    public private(set) var screenName: String?
    public private(set) var currentHeadroom: Double?
    public private(set) var potentialHeadroom: Double?
    public var isHDR: Bool { transfer == "PQ" || transfer == "HLG" }
    public var requestsEDR: Bool { isHDR && screenName != nil && (potentialHeadroom.map { $0 > 1 } ?? true) }
    public var outputDescription: String {
        guard screenName != nil else { return "Display unavailable" }
        guard transfer != "Waiting for video" else { return "Output idle" }
        guard isHDR else { return "SDR output" }
        return requestsEDR ? "HDR output requested" : "HDR mapped to SDR"
    }
    func update(image: CVPixelBuffer) {
        let tag=CVBufferCopyAttachment(image,kCVImageBufferTransferFunctionKey,nil)
        if let tag,CFEqual(tag,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) { transfer="PQ" }
        else if let tag,CFEqual(tag,kCVImageBufferTransferFunction_ITU_R_2100_HLG) { transfer="HLG" }
        else { transfer = tag == nil ? "Untagged" : "SDR" }
        let primaries=CVBufferCopyAttachment(image,kCVImageBufferColorPrimariesKey,nil)
        if let primaries,CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_2020) { colorPrimaries="BT.2020" }
        else if let primaries,CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_709_2) { colorPrimaries="BT.709" }
        else if let primaries,CFEqual(primaries,kCVImageBufferColorPrimaries_P3_D65) { colorPrimaries="P3 D65" }
        else { colorPrimaries = primaries == nil ? "Unspecified" : "Other" }
        hasMasteringMetadata=CVBufferCopyAttachment(image,kCVImageBufferMasteringDisplayColorVolumeKey,nil) != nil
        hasContentLightMetadata=CVBufferCopyAttachment(image,kCVImageBufferContentLightLevelInfoKey,nil) != nil
    }
    func reset() {
        transfer="Waiting for video";colorPrimaries="Unspecified"
        hasMasteringMetadata=false;hasContentLightMetadata=false
    }
    func updateDisplay(name: String?,currentHeadroom: Double?,potentialHeadroom: Double?) {
        screenName=name
        self.currentHeadroom=Self.valid(currentHeadroom)
        self.potentialHeadroom=Self.valid(potentialHeadroom)
    }
    private static func valid(_ value: Double?) -> Double? {
        guard let value,value.isFinite,value >= 1 else { return nil };return value
    }
}
