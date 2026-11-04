import XCTest
import CoreMedia
import CoreVideo
import Metal
@testable import MysticStream

final class MetalVideoRendererTests: XCTestCase {
    /// A solid frame, as VideoToolbox would hand one over: IOSurface-backed and tagged.
    private func frame(_ format: OSType,y: UInt16,u: UInt16,v: UInt16,matrix: CFString) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attributes: [CFString:Any]=[kCVPixelBufferIOSurfacePropertiesKey:[:] as [String:Any],kCVPixelBufferMetalCompatibilityKey:true]
        XCTAssertEqual(CVPixelBufferCreate(nil,16,16,format,attributes as CFDictionary,&image),kCVReturnSuccess)
        let buffer=try XCTUnwrap(image)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,matrix,.shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer,[])
        defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let wide=VideoColorConversion(pixelFormat:format,matrix:nil)!.codeScale > 255
        for plane in 0..<2 {
            let base=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,plane))
            let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer,plane) {
                for column in 0..<CVPixelBufferGetWidthOfPlane(buffer,plane) {
                    let values=plane == 0 ? [y] : [u,v]
                    for (index,value) in values.enumerated() {
                        let at=row*stride+(column*values.count+index)*(wide ? 2 : 1)
                        // 10-bit codes sit in the top bits of 16.
                        if wide { base.storeBytes(of:(value << 6).littleEndian,toByteOffset:at,as:UInt16.self) }
                        else { base.storeBytes(of:UInt8(value),toByteOffset:at,as:UInt8.self) }
                    }
                }
            }
        }
        return buffer
    }
    private func draw(_ image: CVPixelBuffer) throws -> [Int] {
        let drawer: MetalFrameDrawer
        do { drawer=try MetalFrameDrawer() } catch { throw XCTSkip("No Metal device") }
        let description=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:4,height:4,mipmapped:false)
        description.usage=[.renderTarget,.shaderRead];description.storageMode = .shared
        let target=try XCTUnwrap(drawer.device.makeTexture(descriptor:description))
        let commands=try XCTUnwrap(drawer.queue.makeCommandBuffer())
        try drawer.encode(image,to:target,commands:commands)
        commands.commit();commands.waitUntilCompleted()
        XCTAssertNil(commands.error)
        var pixel=[UInt8](repeating:0,count:4)
        target.getBytes(&pixel,bytesPerRow:16,from:MTLRegionMake2D(1,1,1,1),mipmapLevel:0)
        return pixel.prefix(3).map(Int.init)
    }
    private func assertColor(_ actual: [Int],_ expected: [Int],line: UInt = #line) {
        for (a,e) in zip(actual,expected) { XCTAssertEqual(a,e,accuracy:3,"\(actual) vs \(expected)",line:line) }
    }
    func testEightBitVideoRangeColorsMatchTheirCodes() throws {
        let format=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,bt709=kCVImageBufferYCbCrMatrix_ITU_R_709_2
        assertColor(try draw(frame(format,y:235,u:128,v:128,matrix:bt709)),[255,255,255])
        assertColor(try draw(frame(format,y:16,u:128,v:128,matrix:bt709)),[0,0,0])
        assertColor(try draw(frame(format,y:63,u:102,v:240,matrix:bt709)),[255,0,0])
        assertColor(try draw(frame(format,y:32,u:240,v:118,matrix:bt709)),[0,0,255])
    }
    func testTenBitCodesAndTheBT2020MatrixMatch() throws {
        let format=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,bt2020=kCVImageBufferYCbCrMatrix_ITU_R_2020
        assertColor(try draw(frame(format,y:940,u:512,v:512,matrix:bt2020)),[255,255,255])
        assertColor(try draw(frame(format,y:64,u:512,v:512,matrix:bt2020)),[0,0,0])
        // BT.2020 red: Y' = 0.2627, Cb = -0.1396, Cr = 0.5.
        assertColor(try draw(frame(format,y:294,u:387,v:960,matrix:bt2020)),[255,0,0])
    }
    func testFullRangeUsesTheWholeScale() throws {
        let format=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,bt709=kCVImageBufferYCbCrMatrix_ITU_R_709_2
        assertColor(try draw(frame(format,y:255,u:128,v:128,matrix:bt709)),[255,255,255])
        assertColor(try draw(frame(format,y:0,u:128,v:128,matrix:bt709)),[0,0,0])
    }
    func testPrewarmBuildsBothLayerFormatsBeforeAFrameAsks() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let pipelines=MetalVideoPipelines(device:device)
        XCTAssertFalse(MetalVideoPipelines.layerFormats.contains { pipelines.isBuilt($0) })
        pipelines.prewarm();pipelines.prewarm()
        let deadline=Date().addingTimeInterval(10)
        while !MetalVideoPipelines.layerFormats.allSatisfy({ pipelines.isBuilt($0) }),Date() < deadline { usleep(5_000) }
        for format in MetalVideoPipelines.layerFormats { XCTAssertTrue(pipelines.isBuilt(format),"\(format)") }
        let first=try pipelines.pipeline(.bgra8Unorm)
        XCTAssertTrue(first === (try pipelines.pipeline(.bgra8Unorm)),"a built pipeline is reused")
        XCTAssertFalse(pipelines.isBuilt(.rgba8Unorm),"other formats wait to be asked for")
        _=try pipelines.pipeline(.rgba8Unorm);XCTAssertTrue(pipelines.isBuilt(.rgba8Unorm))
    }
    /// The app's path: the shader source compiled as build-macos-app.sh compiles it, then loaded.
    func testThePrecompiledShadersLoadAndBuildAPipeline() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let source=try XCTUnwrap(MetalVideoPipelines.sourceURL)
        let output=FileManager.default.temporaryDirectory.appendingPathComponent("VideoShaders-\(UUID()).metallib")
        defer { try? FileManager.default.removeItem(at:output) }
        let compile=Process()
        compile.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun")
        compile.arguments=["-sdk","macosx","metal","-Werror","-mmacosx-version-min=27.0","-o",output.path,source.path]
        try compile.run();compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { throw XCTSkip("The Metal Toolchain is not installed") }
        let library=try MetalVideoPipelines.library(device:device,precompiled:output)
        XCTAssertNotNil(library.makeFunction(name:"videoVertex"));XCTAssertNotNil(library.makeFunction(name:"videoFragment"))
        let description=MTLRenderPipelineDescriptor()
        description.vertexFunction=library.makeFunction(name:"videoVertex");description.fragmentFunction=library.makeFunction(name:"videoFragment")
        description.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor:description))
    }
    func testAMissingOrBrokenMetallibFallsBackToTheSource() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let broken=FileManager.default.temporaryDirectory.appendingPathComponent("Broken-\(UUID()).metallib")
        try Data("not a library".utf8).write(to:broken);defer { try? FileManager.default.removeItem(at:broken) }
        for precompiled in [nil,broken] {
            XCTAssertNotNil(try MetalVideoPipelines.library(device:device,precompiled:precompiled).makeFunction(name:"videoFragment"))
        }
    }
    func testEveryLayerFormatIsPrewarmed() throws {
        let image=try frame(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,y:64,u:512,v:512,matrix:kCVImageBufferYCbCrMatrix_ITU_R_2020)
        CVBufferSetAttachment(image,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
        XCTAssertTrue(MetalVideoPipelines.layerFormats.contains(VideoLayerFormat(image:image).pixelFormat))
        let sdr=try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,y:16,u:128,v:128,matrix:kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        XCTAssertTrue(MetalVideoPipelines.layerFormats.contains(VideoLayerFormat(image:sdr).pixelFormat))
    }
    func testTheTimelineRunsFromItsRestartWithoutFrames() {
        nonisolated(unsafe) var host=CMTime(value:5,timescale:1)
        let timeline=MetalTimeline(clock:{ host })
        XCTAssertEqual(timeline.now(),.zero)
        host=CMTime(value:7,timescale:1)
        XCTAssertEqual(timeline.now(),CMTime(value:2,timescale:1))
        timeline.restart();XCTAssertEqual(timeline.now(),.zero)
        host=CMTime(value:8,timescale:1)
        XCTAssertEqual(timeline.now(),CMTime(value:1,timescale:1))
    }
    func testTheNewestFrameIsDrawnAndReplacedOnesCountAsMissed() {
        let slot=MetalFrameSlot<Int>()
        XCTAssertTrue(slot.offer(1),"the first frame starts a drain")
        XCTAssertFalse(slot.offer(2),"one drain at a time")
        XCTAssertFalse(slot.offer(3))
        XCTAssertEqual(slot.missed,2)
        XCTAssertTrue(slot.isWaiting)
        XCTAssertEqual(slot.take(),3,"a drawable goes to the newest")
        XCTAssertFalse(slot.isWaiting,"nothing left ends the drain")
        XCTAssertTrue(slot.offer(4),"so the next frame starts another")
        slot.discardWaiting();XCTAssertEqual(slot.missed,3,"a drawable timeout misses the frame")
        XCTAssertFalse(slot.isWaiting)
        XCTAssertTrue(slot.offer(5));slot.clear()
        XCTAssertEqual(slot.missed,3,"a flush is not a miss");XCTAssertNil(slot.take())
        slot.countMissed();XCTAssertEqual(slot.missed,4)
    }
    func testAnInOrderSlotDrawsOldestFirstAndMissesOnlyPastItsCapacity() {
        let slot=MetalFrameSlot<Int>(capacity:3)
        XCTAssertTrue(slot.offer(1));XCTAssertFalse(slot.offer(2));XCTAssertFalse(slot.offer(3))
        XCTAssertEqual(slot.missed,0)
        XCTAssertFalse(slot.offer(4));XCTAssertEqual(slot.missed,1)
        XCTAssertEqual(slot.take(),2);XCTAssertTrue(slot.isWaiting)
        slot.discardWaiting();XCTAssertEqual(slot.missed,2,"a drawable timeout misses one frame")
        XCTAssertEqual(slot.take(),4);XCTAssertFalse(slot.isWaiting)
    }
    @MainActor func testTheLayerFollowsThePacingsRefreshWait() throws {
        do {
            let free=try MetalPresentationReceiver(clock:{ .zero },waitsForRefresh:false)
            XCTAssertFalse(free.layer.displaySyncEnabled);XCTAssertEqual(free.layer.maximumDrawableCount,3)
            let synced=try MetalPresentationReceiver(clock:{ .zero })
            XCTAssertTrue(synced.layer.displaySyncEnabled);XCTAssertEqual(synced.layer.maximumDrawableCount,2)
        } catch VideoDecoderError.unsupported { throw XCTSkip("No Metal device") }
    }
    func testTheDrawableIsThePicturesSizeOnceThereIsOne() {
        let frame=CGRect(x:0,y:0,width:1512,height:945)
        XCTAssertEqual(DisplayLayerPresenter.drawableSize(video:.zero,frame:frame,pixelsPerPoint:2),CGSize(width:3024,height:1890),
                       "before the first frame, the frame's pixels")
        XCTAssertEqual(DisplayLayerPresenter.drawableSize(video:CGSize(width:1920,height:1080),frame:frame,pixelsPerPoint:2),CGSize(width:1920,height:1080),
                       "the display scales the picture into the frame")
        XCTAssertEqual(DisplayLayerPresenter.drawableSize(video:CGSize(width:1919.6,height:1080.2),frame:frame,pixelsPerPoint:2),CGSize(width:1920,height:1080))
    }
    func testADrawFailureIsReportedOnce() {
        let slot=MetalFrameSlot<Int>()
        XCTAssertNil(slot.takeFailure())
        slot.fail(VideoDecoderError.invalidSample("x"))
        XCTAssertNotNil(slot.takeFailure());XCTAssertNil(slot.takeFailure())
    }
    func testTagsChooseTheLayerFormat() throws {
        let image=try frame(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,y:64,u:512,v:512,matrix:kCVImageBufferYCbCrMatrix_ITU_R_2020)
        // 10-bit SDR keeps its depth to the screen; 8-bit SDR stays 8-bit.
        XCTAssertEqual(VideoLayerFormat(image:image).transfer,.sdr);XCTAssertEqual(VideoLayerFormat(image:image).pixelFormat,.bgr10a2Unorm)
        let eight=try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,y:16,u:128,v:128,matrix:kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        XCTAssertEqual(VideoLayerFormat(image:eight).pixelFormat,.bgra8Unorm)
        CVBufferSetAttachment(image,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,.shouldPropagate)
        XCTAssertEqual(VideoLayerFormat(image:image).transfer,.pq);XCTAssertEqual(VideoLayerFormat(image:image).pixelFormat,.bgr10a2Unorm)
        CVBufferSetAttachment(image,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_2100_HLG,.shouldPropagate)
        XCTAssertEqual(VideoLayerFormat(image:image).transfer,.hlg)
        XCTAssertNil(VideoColorConversion(pixelFormat:kCVPixelFormatType_32BGRA,matrix:nil))
    }
}
