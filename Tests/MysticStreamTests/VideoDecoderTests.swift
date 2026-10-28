import XCTest
import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import MysticCore
import MysticKit
@testable import MysticStream

@MainActor
final class VideoDecoderTests: XCTestCase {
    private static var report: VideoCapabilities?
    private func capabilities() async -> VideoCapabilities {
        if let report = Self.report { return report }
        let report = await VideoCapabilities.probe()
        Self.report = report
        for format in VideoFormat.allCases {
            print("CAPABILITY \(format): \(report.exclusionReasons[format.rawValue] ?? "supported")")
        }
        return report
    }
    private func verify(_ format: VideoFormat) async throws {
        // Parser correctness is required even on Macs lacking the codec hardware.
        let fixture = try VideoCapabilities.fixture(format)
        let compressed = try CompressedVideo.make(fixture, format: format, previous: nil)
        XCTAssertFalse(compressed.configuration.isEmpty)
        if format.isAV1 {
            let config = try XCTUnwrap(AV1.configuration(in: fixture))
            XCTAssertEqual(config.bitDepth, format.tenBit ? 10 : 8)
            XCTAssertEqual(config.chroma444, format.chroma444)
            XCTAssertEqual(config.width, 64); XCTAssertEqual(config.height, 64)
            // Every truncated sequence header must fail rather than produce a configuration.
            let sequence = try XCTUnwrap(AV1.units(in: fixture).first { $0.type == 1 })
            for count in 1..<sequence.bytes.count {
                XCTAssertThrowsError(try AV1.configuration(in: Data(sequence.bytes.prefix(count))))
            }
        }
        let report = await capabilities()
        guard report.supportedFormats & format.rawValue != 0 else {
            throw XCTSkip(report.exclusionReasons[format.rawValue] ?? "unsupported hardware")
        }
        let decoded = CollectedFrames()
        let decoder = VideoToolboxDecoder(capabilities: report, output: { decoded.append($0) })
        try decoder.setup(VideoSetupInfo(format: format.rawValue, width: 64, height: 64, fps: 60, colorRange: 0))
        decoder.start()
        XCTAssertEqual(submit(decoder, data: fixture, key: true, hdr: format.tenBit), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(decoded.count, 1)
        decoder.cleanup()
        let frame = try VideoCapabilities.decodeFixture(format)
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 64)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.pixelBuffer), format.pixelFormat(fullRange: false))
        XCTAssertNotNil(CVPixelBufferGetIOSurface(frame.pixelBuffer))
        let sample = try frame.sampleBuffer()
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 1234567, timescale: 1_000_000)), 0)
        let desc = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertNotNil(CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries))
        XCTAssertNotNil(CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction))
        if format == .hevc10 || format == .hevc10444 {
            XCTAssertNotNil(CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil))
            XCTAssertNotNil(CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferContentLightLevelInfoKey, nil))
            XCTAssertNotNil(CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume))
            XCTAssertNotNil(CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo))
        }
    }
    func testH264() async throws { try await verify(.h264) }
    func testH264444() async throws { try await verify(.h264444) }
    func testHEVC() async throws { try await verify(.hevc) }
    func testHEVC10() async throws { try await verify(.hevc10) }
    func testHEVC444() async throws { try await verify(.hevc444) }
    func testHEVC10444() async throws { try await verify(.hevc10444) }
    func testAV1() async throws { try await verify(.av1) }
    func testAV110() async throws { try await verify(.av110) }
    func testAV1444() async throws { try await verify(.av1444) }
    func testAV110444() async throws { try await verify(.av110444) }

    func testBaselineAndUnsupportedSetup() async throws {
        let report = await capabilities()
        // A broken parser/display probe must not turn baseline H.264 into a silent skip.
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) {
            XCTAssertNotEqual(report.supportedFormats & VideoFormat.h264.rawValue, 0,
                              report.exclusionReasons[1] ?? "H.264 unavailable")
        }
        let decoder = VideoToolboxDecoder(capabilities: report, output: { _ in })
        XCTAssertThrowsError(try decoder.setup(VideoSetupInfo(format: 0x10000, width: 64, height: 64, fps: 60)))
        XCTAssertThrowsError(try decoder.setup(VideoSetupInfo(format: 3, width: 64, height: 64, fps: 60)))
        XCTAssertThrowsError(try decoder.setup(VideoSetupInfo(format: 1, width: 0, height: 64, fps: 60)))
        XCTAssertEqual(report.supportedFormats & 0xF0000, 0)
        decoder.stop(); decoder.stop(); decoder.cleanup(); decoder.cleanup()
    }

    func testLifecycleAndRecovery() async throws {
        let report = await capabilities()
        guard report.supportedFormats & 1 != 0 else { throw XCTSkip("no H.264 hardware") }
        let frames = CollectedFrames()
        let decoder = VideoToolboxDecoder(capabilities: report, output: { frames.append($0) })
        let setup = VideoSetupInfo(format: 1, width: 64, height: 64, fps: 60, colorSpace: 1, colorRange: 0)
        let data = try VideoCapabilities.fixture(.h264)
        try decoder.setup(setup); decoder.start()
        XCTAssertEqual(submit(decoder, data: data, key: false), .needIDR)
        XCTAssertEqual(submit(decoder, data: data, key: true), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.lastPTS, .zero)
        decoder.presentationFailed("injected asynchronous renderer error")
        XCTAssertEqual(submit(decoder, data: data, key: false), .needIDR)
        XCTAssertEqual(submit(decoder, data: data, key: true, time: 101), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(submit(decoder, data: Data([1,2,3]), key: true), .needIDR)
        XCTAssertEqual(submit(decoder, data: data, key: false), .needIDR)
        decoder.stop(); decoder.cleanup()
        XCTAssertEqual(submit(decoder, data: data, key: true), .needIDR)
        try decoder.setup(setup); decoder.start()
        XCTAssertEqual(submit(decoder, data: data, key: true, time: UInt64.max), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(frames.lastPTS, .zero)
        decoder.stop()
    }

    func testDependentFramesAndChangedParameterSets() async throws {
        let report = await capabilities()
        guard report.supportedFormats & 1 != 0 else { throw XCTSkip("no H.264 hardware") }
        let frames = CollectedFrames()
        let decoder = VideoToolboxDecoder(capabilities: report, output: { frames.append($0) })
        try decoder.setup(VideoSetupInfo(format: 1, width: 64, height: 64, fps: 60, colorRange: 0))
        decoder.start()
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures")))
        }
        let key = try fixture("h264-key"), delta = try fixture("h264-p"), resize = try fixture("h264-resize")
        XCTAssertEqual(submit(decoder, data: key, key: true), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(submit(decoder, data: delta, key: false, time: 16_767), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.lastPTS, CMTime(value: 16667, timescale: 1_000_000))
        // A new configuration outside a keyframe must trigger recovery.
        XCTAssertEqual(submit(decoder, data: resize, key: false, time: 33_434), .needIDR)
        XCTAssertEqual(submit(decoder, data: resize, key: true, time: 33_434), .ok)
        decoder.waitForFrames()
        XCTAssertEqual(frames.lastWidth, 128)
        decoder.stop()
        // The copied compressed sample outlives the callback's borrowed Data storage.
        XCTAssertEqual(frames.count, 3)
    }

    func testPresenterDisplaysAndClearsOnStop() async throws {
        let report = await capabilities()
        guard report.supportedFormats & 1 != 0 else { throw XCTSkip("no H.264 hardware") }
        let telemetry = VideoTelemetry()
        let presenter = DisplayLayerPresenter(telemetry:telemetry)
        presenter.layer.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let decoder = VideoToolboxDecoder(capabilities: report, presenter: presenter,telemetry:telemetry)
        try decoder.setup(VideoSetupInfo(format: 1, width: 64, height: 64, fps: 60, colorRange: 0))
        decoder.start()
        let fixture = try VideoCapabilities.fixture(.h264)
        let disposition = fixture.withUnsafeBytes { bytes in
            decoder.submit(VideoFrameInfo(number:1,isKeyFrame:true,hostProcessingLatencyTenthMs:13,
                receiveTimeMicros:9_000_000,enqueueTimeMicros:9_002_300,presentationTimeMicros:100,
                rtpTimestamp:0,hdrActive:false,colorspace:1,data:bytes))
        }
        XCTAssertEqual(disposition,.ok)
        decoder.waitForFrames()
        for _ in 0..<50 {
            if telemetry.snapshot().enqueued == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.submitted,1);XCTAssertEqual(snapshot.decoded,1);XCTAssertEqual(snapshot.enqueued,1)
        XCTAssertEqual(snapshot.timings[.hostProcessing]?.p50Micros,1300)
        XCTAssertEqual(snapshot.timings[.reassembly]?.p50Micros,2300)
        XCTAssertEqual(snapshot.timings.count,6)
        let local = try XCTUnwrap(snapshot.timings[.clientToEnqueue]?.p50Micros)
        let decode = try XCTUnwrap(snapshot.timings[.decode]?.p50Micros)
        XCTAssertGreaterThanOrEqual(local,decode)
        XCTAssertTrue(presenter.layer.isReadyForDisplay)
        decoder.stop()
        for _ in 0..<50 {
            if !presenter.layer.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(presenter.layer.isReadyForDisplay)
        decoder.cleanup()
    }

    func testCompletionBoundsAndStaleCallbacks() {
        let state = DecodeCompletionState()
        state.reset(generation: 7)
        for _ in 0..<3 { XCTAssertTrue(state.reserve(generation: 7)) }
        XCTAssertFalse(state.reserve(generation: 7))
        state.reset(generation: 8)
        XCTAssertFalse(state.complete(generation: 7))
        state.fail(generation: 7)
        XCTAssertFalse(state.takeFailure())
        state.fail(generation: 8)
        XCTAssertTrue(state.takeFailure()); XCTAssertFalse(state.takeFailure())
        XCTAssertTrue(state.reserve(generation: 8))
    }

    func testMailboxCoalescesAndRejectsStaleGenerations() throws {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &image), 0)
        let pixel = try XCTUnwrap(image)
        let mailbox = PresentationMailbox()
        XCTAssertTrue(mailbox.reset(generation: 4))
        XCTAssertTrue(mailbox.reserveWake())
        for _ in 0..<100 { XCTAssertFalse(mailbox.reserveWake()) }
        XCTAssertEqual(mailbox.finishWake(), 4)
        for n in 0..<100 {
            XCTAssertFalse(mailbox.offer(DecodedVideoFrame(pixelBuffer: pixel, presentationTime: CMTime(value: Int64(n), timescale: 60), generation: 4)))
        }
        XCTAssertEqual(mailbox.take().frame?.presentationTime.value, 99)
        XCTAssertFalse(mailbox.finish())
        XCTAssertTrue(mailbox.reset(generation: 5))
        XCTAssertFalse(mailbox.offer(DecodedVideoFrame(pixelBuffer: pixel, presentationTime: .zero, generation: 4)))
        XCTAssertNil(mailbox.take().frame)
        XCTAssertFalse(mailbox.finish())
    }

    private func submit(_ decoder: VideoToolboxDecoder, data: Data, key: Bool, time: UInt64 = 100, hdr: Bool = false) -> FrameDisposition {
        data.withUnsafeBytes { bytes in
            decoder.submit(VideoFrameInfo(number: 1, isKeyFrame: key, hostProcessingLatencyTenthMs: 0,
                receiveTimeMicros: 0, enqueueTimeMicros: 0, presentationTimeMicros: time,
                rtpTimestamp: 0, hdrActive: hdr, colorspace: 1, data: bytes))
        }
    }
}

private final class CollectedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [DecodedVideoFrame] = []
    func append(_ frame: DecodedVideoFrame) { lock.lock(); frames.append(frame); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    var lastWidth: Int? { lock.lock(); defer { lock.unlock() }; return frames.last.map { CVPixelBufferGetWidth($0.pixelBuffer) } }
    var lastPTS: CMTime? { lock.lock(); defer { lock.unlock() }; return frames.last?.presentationTime }
}
