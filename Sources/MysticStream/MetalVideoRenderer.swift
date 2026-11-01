import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import MysticCore

/// YCbCr to the source's own nonlinear RGB. Transfer and primaries stay as tagged: the layer's
/// color space says what they are, and macOS owns any mapping to the screen, as with the display layer.
struct VideoColorConversion: Equatable {
    var yOffset: Float,yScale: Float,cOffset: Float,cScale: Float
    /// A normalized sample times this is its code value.
    var codeScale: Float
    var kr: Float,kb: Float
    init?(pixelFormat: OSType,matrix: CFString?) {
        let tenBit,fullRange: Bool
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: (tenBit,fullRange)=(false,false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: (tenBit,fullRange)=(false,true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: (tenBit,fullRange)=(true,false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: (tenBit,fullRange)=(true,true)
        default: return nil
        }
        // 10-bit codes sit in the top bits of 16.
        codeScale=tenBit ? 65535/64 : 255
        let unit: Float=tenBit ? 4 : 1
        cOffset=128*unit
        if fullRange { yOffset=0;yScale=255*unit+(tenBit ? 3 : 0);cScale=yScale }
        else { yOffset=16*unit;yScale=219*unit;cScale=224*unit }
        if let matrix,CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_2020) { (kr,kb)=(0.2627,0.0593) }
        else if let matrix,CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_601_4) { (kr,kb)=(0.299,0.114) }
        else { (kr,kb)=(0.2126,0.0722) }
    }
}

/// What a frame's tags ask of its layer.
struct VideoLayerFormat: Equatable {
    enum Transfer: Equatable { case sdr,pq,hlg }
    let transfer: Transfer
    let colorSpaceName: CFString
    init(image: CVPixelBuffer) {
        let tag=CVBufferCopyAttachment(image,kCVImageBufferTransferFunctionKey,nil)
        let primaries=CVBufferCopyAttachment(image,kCVImageBufferColorPrimariesKey,nil)
        if let tag,CFEqual(tag,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
            transfer = .pq;colorSpaceName=CGColorSpace.itur_2100_PQ
        } else if let tag,CFEqual(tag,kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            transfer = .hlg;colorSpaceName=CGColorSpace.itur_2100_HLG
        } else {
            transfer = .sdr
            if let primaries,CFEqual(primaries,kCVImageBufferColorPrimaries_P3_D65) { colorSpaceName=CGColorSpace.displayP3 }
            else if let primaries,CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_2020) { colorSpaceName=CGColorSpace.itur_2020 }
            else { colorSpaceName=CGColorSpace.itur_709 }
        }
    }
    var pixelFormat: MTLPixelFormat { transfer == .sdr ? .bgra8Unorm : .bgr10a2Unorm }
}

private let videoShaders="""
#include <metal_stdlib>
using namespace metal;
struct Conversion { float yOffset,yScale,cOffset,cScale,codeScale,kr,kb; };
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex videoVertex(uint id [[vertex_id]]) {
    float2 uv=float2((id << 1) & 2,id & 2);
    return { float4(uv*float2(2,-2)+float2(-1,1),0,1),uv };
}
fragment float4 videoFragment(Vertex in [[stage_in]],texture2d<float> luma [[texture(0)]],texture2d<float> chroma [[texture(1)]],
                              constant Conversion &c [[buffer(0)]]) {
    constexpr sampler linear(filter::linear,address::clamp_to_edge);
    float y=(luma.sample(linear,in.uv).r*c.codeScale-c.yOffset)/c.yScale;
    float2 uv=(chroma.sample(linear,in.uv).rg*c.codeScale-c.cOffset)/c.cScale;
    float r=y+2*(1-c.kr)*uv.y,b=y+2*(1-c.kb)*uv.x;
    float g=(y-c.kr*r-c.kb*b)/(1-c.kr-c.kb);
    return float4(saturate(float3(r,g,b)),1);
}
"""

/// Draws decoded IOSurfaces without a CPU copy. Used on one queue at a time.
final class MetalFrameDrawer: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let cache: CVMetalTextureCache
    private var pipelines: [MTLPixelFormat:any MTLRenderPipelineState]=[:]
    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw VideoDecoderError.unsupported("Metal is unavailable") }
        var cache: CVMetalTextureCache?
        try checked(CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache),"Metal texture cache")
        guard let cache else { throw VideoDecoderError.unsupported("Metal texture cache is unavailable") }
        self.device=device;self.queue=queue;self.cache=cache
        library=try device.makeLibrary(source:videoShaders,options:nil)
    }
    private func pipeline(_ format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
        if let existing=pipelines[format] { return existing }
        let description=MTLRenderPipelineDescriptor()
        description.vertexFunction=library.makeFunction(name:"videoVertex")
        description.fragmentFunction=library.makeFunction(name:"videoFragment")
        description.colorAttachments[0].pixelFormat=format
        let state=try device.makeRenderPipelineState(descriptor:description)
        pipelines[format]=state
        return state
    }
    private func plane(_ image: CVPixelBuffer,_ index: Int,_ format: MTLPixelFormat) throws -> (CVMetalTexture,any MTLTexture) {
        var texture: CVMetalTexture?
        try checked(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,image,nil,format,
            CVPixelBufferGetWidthOfPlane(image,index),CVPixelBufferGetHeightOfPlane(image,index),index,&texture),"video plane")
        guard let texture,let metal=CVMetalTextureGetTexture(texture) else { throw VideoDecoderError.invalidSample("video plane has no texture") }
        return (texture,metal)
    }
    /// Encodes one frame filling `target`; the planes stay alive until the buffer completes.
    func encode(_ image: CVPixelBuffer,to target: any MTLTexture,commands: any MTLCommandBuffer) throws {
        let format=CVPixelBufferGetPixelFormatType(image)
        let matrix=CVBufferCopyAttachment(image,kCVImageBufferYCbCrMatrixKey,nil) as! CFString?
        guard let conversion=VideoColorConversion(pixelFormat:format,matrix:matrix) else {
            throw VideoDecoderError.unsupported("Metal cannot draw pixel format \(format)")
        }
        let sixteen=conversion.codeScale > 255
        let luma=try plane(image,0,sixteen ? .r16Unorm : .r8Unorm),chroma=try plane(image,1,sixteen ? .rg16Unorm : .rg8Unorm)
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder=commands.makeRenderCommandEncoder(descriptor:pass) else { throw VideoDecoderError.invalidSample("no render encoder") }
        encoder.setRenderPipelineState(try pipeline(target.pixelFormat))
        encoder.setFragmentTexture(luma.1,index:0);encoder.setFragmentTexture(chroma.1,index:1)
        var values=[conversion.yOffset,conversion.yScale,conversion.cOffset,conversion.cScale,conversion.codeScale,conversion.kr,conversion.kb]
        encoder.setFragmentBytes(&values,length:MemoryLayout<Float>.stride*values.count,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        commands.addCompletedHandler { _ in withExtendedLifetime((luma.0,chroma.0,image)) {} }
    }
}

/// Stands where the display layer's receiver does, so the presenter's pacing, resets and failures
/// are the same on either path. Drawing and waits for a drawable stay off the main actor.
@MainActor
final class MetalPresentationReceiver: PresentationReceiver {
    let layer=CAMetalLayer()
    private let drawer: MetalFrameDrawer
    private let renderQueue=DispatchQueue(label:"mystic.video.metal",qos:.userInteractive)
    /// The presenter's timeline, to turn a frame's timestamp into a moment.
    private let clock: @Sendable () -> CMTime
    private nonisolated let slot: MetalFrameSlot<RenderFrame>
    private var lastFormat: VideoLayerFormat?
    /// Seconds since the decoder finished the frame about to be enqueued.
    var nextFrameAge: CFTimeInterval?
    init(clock: @escaping @Sendable () -> CMTime,capacity: Int = 1,waitsForRefresh: Bool = true) throws {
        drawer=try MetalFrameDrawer();self.clock=clock;slot=MetalFrameSlot(capacity:capacity)
        layer.device=drawer.device
        layer.framebufferOnly=true;layer.isOpaque=true
        // Two made a frame wait out a refresh for a drawable, and at 120 Hz most were then superseded.
        layer.maximumDrawableCount=3
        // Off about halved decoded-to-screen time; see METAL-RENDERER.md.
        layer.displaySyncEnabled=waitsForRefresh
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace=CGColorSpace(name:CGColorSpace.itur_709)
        layer.backgroundColor=CGColor(gray:0,alpha:1)
    }
    func setDrawableSize(_ size: CGSize) {
        guard size.width >= 1,size.height >= 1 else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.drawableSize=size
        CATransaction.commit()
    }
    /// Hands the frame over at once; the render queue draws the slot's next frame when a drawable is free.
    func enqueue(_ sample: sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult {
        if let failure=slot.takeFailure() { throw failure }
        guard let image=CMSampleBufferGetImageBuffer(sample) else { throw VideoDecoderError.invalidSample("sample has no image") }
        let format=VideoLayerFormat(image:image)
        if format != lastFormat { configure(format,image:image);lastFormat=format }
        if slot.offer(RenderFrame(image:image,time:CMSampleBufferGetPresentationTimeStamp(sample),
                                  readySeconds:nextFrameAge.map { CACurrentMediaTime()-$0 },enqueuedSeconds:CACurrentMediaTime())) {
            let target=UnsafeLayer(layer:layer),drawer=drawer,clock=clock,slot=slot
            renderQueue.async { Self.drain(target,drawer,clock,slot) }
        }
        return .enqueued
    }
    /// Waits for the drawable first, so the wait never leaves an older frame to be drawn.
    private nonisolated static func drain(_ target: UnsafeLayer,_ drawer: MetalFrameDrawer,_ clock: @Sendable () -> CMTime,_ slot: MetalFrameSlot<RenderFrame>) {
        while slot.isWaiting {
            // A timeout is a frame missed, not a failed stream.
            guard let drawable=target.layer.nextDrawable() else { slot.discardWaiting();continue }
            guard let frame=slot.take() else { continue }
            let picked=CACurrentMediaTime()
            guard let commands=drawer.queue.makeCommandBuffer() else { slot.countMissed();continue }
            do {
                try drawer.encode(frame.image,to:drawable.texture,commands:commands)
                let times=FrameTimes()
                commands.addCompletedHandler { _ in times.set(CACurrentMediaTime()) }
                drawable.addPresentedHandler { [committed=CACurrentMediaTime()] in
                    if $0.presentedTime == 0 { slot.countMissed();return }
                    slot.recordShown(seconds:$0.presentedTime,ready:frame.readySeconds)
                    guard let ready=frame.readySeconds,let completed=times.get() else { return }
                    func micros(_ from: CFTimeInterval,_ to: CFTimeInterval) -> Int64 { Int64((to-from)*1_000_000) }
                    slot.recordStages(PresentationStages(toEnqueue:micros(ready,frame.enqueuedSeconds),forDrawable:micros(frame.enqueuedSeconds,picked),
                        encode:micros(picked,committed),gpu:micros(committed,completed),toScreen:micros(completed,$0.presentedTime)))
                }
                let wait=CMTimeGetSeconds(CMTimeSubtract(frame.time,clock()))
                if wait.isFinite,wait > 0.001 { commands.present(drawable,atTime:CACurrentMediaTime()+wait) }
                else { commands.present(drawable) }
                commands.commit()
            } catch { slot.fail(error) }
        }
    }
    /// Frames replaced, timed out or never shown, like the display layer's own drop count.
    var droppedFrames: UInt64 { slot.missed }
    var cadence: ShownCadence { slot.cadence }
    /// macOS tone maps from the metadata, as it does for the display layer.
    private func configure(_ format: VideoLayerFormat,image: CVPixelBuffer) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.pixelFormat=format.pixelFormat
        layer.colorspace=CGColorSpace(name:format.colorSpaceName)
        switch format.transfer {
        case .sdr: layer.edrMetadata=nil;layer.wantsExtendedDynamicRangeContent=false
        case .hlg: layer.edrMetadata = .hlg;layer.wantsExtendedDynamicRangeContent=true
        case .pq:
            let display=CVBufferCopyAttachment(image,kCVImageBufferMasteringDisplayColorVolumeKey,nil) as? Data
            let content=CVBufferCopyAttachment(image,kCVImageBufferContentLightLevelInfoKey,nil) as? Data
            layer.edrMetadata=CAEDRMetadata.hdr10(displayInfo:display,contentInfo:content,opticalOutputScale:100)
            layer.wantsExtendedDynamicRangeContent=true
        }
        CATransaction.commit()
    }
    func flush() { slot.clear() }
    func flush(removingDisplayedImage: Bool) async {
        slot.clear()
        guard removingDisplayedImage else { return }
        let target=UnsafeLayer(layer:layer),drawer=drawer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            renderQueue.async {
                defer { continuation.resume() }
                guard let drawable=target.layer.nextDrawable(),let commands=drawer.queue.makeCommandBuffer() else { return }
                let pass=MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture=drawable.texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor=MTLClearColor(red:0,green:0,blue:0,alpha:1)
                pass.colorAttachments[0].storeAction = .store
                commands.makeRenderCommandEncoder(descriptor:pass)?.endEncoding()
                commands.present(drawable);commands.commit()
            }
        }
    }
}

/// Host time since the stream's first frame. It runs whatever the frames do.
final class MetalTimeline: @unchecked Sendable {
    private let lock=NSLock()
    private let clock: () -> CMTime
    private var origin: CMTime
    init(clock: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }) { self.clock=clock;origin=clock() }
    func restart() { lock.lock();defer { lock.unlock() };origin=clock() }
    func now() -> CMTime { lock.lock();defer { lock.unlock() };return CMTimeSubtract(clock(),origin) }
}

private struct RenderFrame: @unchecked Sendable { let image: CVPixelBuffer;let time: CMTime;let readySeconds: CFTimeInterval?;let enqueuedSeconds: CFTimeInterval }
/// When the GPU finished, from one Metal callback to the next.
private final class FrameTimes: @unchecked Sendable {
    private let lock=NSLock();private var completed: CFTimeInterval?
    func set(_ value: CFTimeInterval) { lock.lock();defer { lock.unlock() };completed=value }
    func get() -> CFTimeInterval? { lock.lock();defer { lock.unlock() };return completed }
}
/// CAMetalLayer's nextDrawable is meant to be called off the main thread.
private struct UnsafeLayer: @unchecked Sendable { let layer: CAMetalLayer }

/// The frames waiting for a drawable, oldest first. Past `capacity` the oldest goes, and that counts
/// as missed; a capacity of one is always the newest frame.
final class MetalFrameSlot<Frame>: @unchecked Sendable {
    private let lock=NSLock()
    private let capacity: Int
    private var frames: [Frame]=[]
    private var draining=false
    private var failure: (any Error)?
    private var missedCount: UInt64=0
    private var shown=ShownCadence()
    init(capacity: Int = 1) { self.capacity=max(1,capacity) }
    /// True when the caller must start draining.
    func offer(_ next: Frame) -> Bool {
        lock.lock();defer { lock.unlock() }
        if frames.count >= capacity { frames.removeFirst();missedCount += 1 }
        frames.append(next)
        if draining { return false };draining=true;return true
    }
    /// Whether to keep draining; false also ends the drain, so `offer` starts another.
    var isWaiting: Bool {
        lock.lock();defer { lock.unlock() }
        if frames.isEmpty { draining=false;return false }
        return true
    }
    func take() -> Frame? { lock.lock();defer { lock.unlock() };return frames.isEmpty ? nil : frames.removeFirst() }
    func discardWaiting() { lock.lock();defer { lock.unlock() };if !frames.isEmpty { missedCount += 1;frames.removeFirst() } }
    /// A flush: the waiting frame is no longer wanted, which is not a miss.
    func clear() { lock.lock();defer { lock.unlock() };frames=[] }
    func countMissed() { lock.lock();defer { lock.unlock() };missedCount += 1 }
    func recordShown(seconds: CFTimeInterval,ready: CFTimeInterval? = nil) {
        lock.lock();defer { lock.unlock() }
        shown.record(presentedMicros:Int64(seconds*1_000_000),readyToShownMicros:ready.map { Int64((seconds-$0)*1_000_000) })
    }
    func recordStages(_ stages: PresentationStages) { lock.lock();defer { lock.unlock() };shown.record(stages:stages) }
    var cadence: ShownCadence { lock.lock();defer { lock.unlock() };return shown }
    var missed: UInt64 { lock.lock();defer { lock.unlock() };return missedCount }
    func fail(_ error: any Error) { lock.lock();defer { lock.unlock() };failure=error }
    /// Reported once, at the next frame, through the presenter's usual failure path.
    func takeFailure() -> (any Error)? { lock.lock();defer { lock.unlock() };defer { failure=nil };return failure }
}
