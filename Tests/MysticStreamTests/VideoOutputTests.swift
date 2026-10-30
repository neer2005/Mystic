import XCTest
import AVFoundation
import CoreVideo
import CoreMedia
import VideoToolbox
@testable import MysticStream

@MainActor
final class VideoOutputTests: XCTestCase {
    func testHDRUsesPotentialHeadroomEvenWhenCurrentHeadroomIsOne() throws {
        let state=VideoOutputState()
        state.updateDisplay(name:"HDR display",currentHeadroom:1,potentialHeadroom:4)
        state.update(image:try image(transfer:kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ))
        XCTAssertTrue(state.requestsEDR)
        XCTAssertEqual(state.transfer,"PQ")
        XCTAssertEqual(state.outputDescription,"HDR output requested")
        state.updateDisplay(name:"SDR display",currentHeadroom:1,potentialHeadroom:1)
        XCTAssertFalse(state.requestsEDR)
        XCTAssertEqual(state.outputDescription,"HDR mapped to SDR")
        state.updateDisplay(name:"HDR display",currentHeadroom:2,potentialHeadroom:4)
        XCTAssertTrue(state.requestsEDR)
        state.reset()
        XCTAssertFalse(state.requestsEDR)
        XCTAssertEqual(state.screenName,"HDR display")
    }
    func testHLGAndSDRTransitionsAndDetachedScreen() throws {
        let state=VideoOutputState()
        state.update(image:try image(transfer:kCVImageBufferTransferFunction_ITU_R_2100_HLG))
        XCTAssertEqual(state.transfer,"HLG");XCTAssertFalse(state.requestsEDR)
        state.updateDisplay(name:"HDR",currentHeadroom:2,potentialHeadroom:4)
        XCTAssertTrue(state.requestsEDR)
        state.update(image:try image(transfer:kCVImageBufferTransferFunction_ITU_R_709_2))
        XCTAssertFalse(state.requestsEDR);XCTAssertEqual(state.transfer,"SDR")
        state.update(image:try image(transfer:nil))
        XCTAssertFalse(state.requestsEDR)
        state.updateDisplay(name:nil,currentHeadroom:nil,potentialHeadroom:nil)
        XCTAssertEqual(state.outputDescription,"Display unavailable")
    }
    func testInvalidHeadroomDoesNotEnterDiagnostics() {
        let state=VideoOutputState()
        for value in [Double.nan,Double.infinity,0,-1] {
            state.updateDisplay(name:"Display",currentHeadroom:value,potentialHeadroom:value)
            XCTAssertNil(state.currentHeadroom);XCTAssertNil(state.potentialHeadroom)
        }
    }
    func testHDRRequiresTransferPrimariesAndMatrixButNotOptionalStaticMetadata() throws {
        let buffer=try image(transfer:nil)
        XCTAssertThrowsError(try validateHDRImage(buffer))
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
        XCTAssertThrowsError(try validateHDRImage(buffer))
        CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
        XCTAssertThrowsError(try validateHDRImage(buffer))
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
        XCTAssertNoThrow(try validateHDRImage(buffer))
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_2100_HLG,.shouldPropagate)
        XCTAssertNoThrow(try validateHDRImage(buffer))
        CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        XCTAssertThrowsError(try validateHDRImage(buffer))
    }
    func testNativeHDRFixtureRequestsEDRPreservesMetadataAndResetsToSDR() async throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { throw XCTSkip("no HEVC hardware") }
        let source=try VideoCapabilities.decodeFixture(.hevc10)
        try validateHDRImage(source.pixelBuffer)
        let presenter=DisplayLayerPresenter()
        presenter.updateDisplay(name:"Test HDR display",currentHeadroom:1,potentialHeadroom:4)
        presenter.reset(generation:source.generation)
        presenter.offer(source)
        for _ in 0..<100 {
            if presenter.layer.isReadyForDisplay { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertTrue(presenter.layer.isReadyForDisplay)
        XCTAssertEqual(presenter.layer.preferredDynamicRange,.high)
        XCTAssertEqual(presenter.layer.toneMapMode,.automatic)
        XCTAssertEqual(presenter.videoOutput.transfer,"PQ")
        XCTAssertEqual(presenter.videoOutput.colorPrimaries,"BT.2020")
        XCTAssertTrue(presenter.videoOutput.hasMasteringMetadata)
        XCTAssertTrue(presenter.videoOutput.hasContentLightMetadata)
        let sample=try source.sampleBuffer()
        let desc=try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        for key in [kCMFormatDescriptionExtension_ColorPrimaries,kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix,kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
                    kCMFormatDescriptionExtension_ContentLightLevelInfo] {
            XCTAssertNotNil(CMFormatDescriptionGetExtension(desc,extensionKey:key))
        }
        presenter.updateDisplay(name:"SDR",currentHeadroom:1,potentialHeadroom:1)
        XCTAssertEqual(presenter.layer.preferredDynamicRange,.standard)
        presenter.updateDisplay(name:"HDR",currentHeadroom:2,potentialHeadroom:4)
        XCTAssertEqual(presenter.layer.preferredDynamicRange,.high)
        presenter.reset(generation:source.generation+1)
        for _ in 0..<100 {
            if presenter.videoOutput.transfer == "Waiting for video" { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertEqual(presenter.layer.preferredDynamicRange,.standard)
        XCTAssertEqual(presenter.videoOutput.transfer,"Waiting for video")
        presenter.offer(source) // The old generation must not re-enable HDR after stop.
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(presenter.layer.preferredDynamicRange,.standard)
    }
    private func image(transfer: CFString?) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,nil,&image),kCVReturnSuccess)
        let result=try XCTUnwrap(image)
        if let transfer { CVBufferSetAttachment(result,kCVImageBufferTransferFunctionKey,transfer,.shouldPropagate) }
        return result
    }
}
