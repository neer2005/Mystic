import CMystic
import Testing
import MysticCore
@testable import MysticKit

/// The C-to-Swift field mapping is the place where a swapped or forgotten field would produce
/// a stream that looks subtly wrong instead of failing, so every field is asserted with a
/// distinct value.
@Suite("Consumer mapping")
struct ConsumerMappingTests {

    @Test("controller feedback preserves motor values and slot epoch")
    func controllerFeedbackMapping() {
        var c=MysticControllerFeedback()
        c.slot=3;c.kind=2;c.first=0x1234;c.second=0xFEDC;c.epoch=0xFEDCBA9876543210
        #expect(ControllerFeedback(c) == ControllerFeedback(slot:3,kind:.triggerRumble,first:0x1234,second:0xFEDC,epoch:0xFEDCBA9876543210))
        c.kind=99;#expect(ControllerFeedback(c) == nil)
        c.kind=1;c.slot=4;#expect(ControllerFeedback(c) == nil)
    }

    @Test("video setup maps every field")
    func videoSetupMapping() {
        var c = MysticVideoSetup()
        c.format = 0x0000_0002
        c.width = 1920
        c.height = 1080
        c.fps = 60
        c.chroma_packing = 3
        c.logical_width = 1280
        c.logical_height = 720
        c.color_space = 1
        c.color_range = 2

        let info = VideoSetupInfo(c)

        #expect(info.format == 0x0000_0002)
        #expect(info.width == 1920)
        #expect(info.height == 1080)
        #expect(info.fps == 60)
        #expect(info.chromaPacking == 3)
        #expect(info.logicalWidth == 1280)
        #expect(info.logicalHeight == 720, "logical width and height are swapped")
        #expect(info.colorSpace == 1)
        #expect(info.colorRange == 2)
    }

    @Test("audio setup maps every field")
    func audioSetupMapping() {
        var c = MysticAudioSetup()
        c.channel_count = 6
        c.channel_mask = 0x3F
        c.packet_duration_ms = 10
        c.samples_per_frame = 480
        c.sample_rate = 48000
        c.streams = 4
        c.coupled_streams = 2
        c.mapping = (0,4,1,5,2,3,6,7)

        let info = AudioSetupInfo(c)

        #expect(info.channelCount == 6)
        #expect(info.channelMask == 0x3F)
        #expect(info.packetDurationMs == 10)
        #expect(info.samplesPerFrame == 480)
        #expect(info.sampleRate == 48000)
        #expect(info.streams == 4)
        #expect(info.coupledStreams == 2)
        #expect(info.mapping == [0,4,1,5,2,3])
    }

    @Test("frame type becomes isKeyFrame")
    func frameTypeMapping() {
        var idr = MysticFrame()
        idr.frame_type = 1
        #expect(VideoFrameInfo(idr).isKeyFrame)

        var pFrame = MysticFrame()
        pFrame.frame_type = 0
        #expect(!VideoFrameInfo(pFrame).isKeyFrame)
    }

    @Test("frame timing fields map without shifting")
    func frameTimingMapping() {
        var c = MysticFrame()
        c.number = 4242
        c.host_processing_latency = 37
        c.receive_time_us = 1_000_000
        c.enqueue_time_us = 1_000_500
        c.presentation_time_us = 1_001_000
        c.rtp_timestamp = 90_000
        c.hdr_active = true
        c.colorspace = 2
        c.data = nil
        c.data_len = 0

        let frame = VideoFrameInfo(c)

        #expect(frame.number == 4242)
        #expect(frame.hostProcessingLatencyTenthMs == 37)
        #expect(frame.receiveTimeMicros == 1_000_000)
        #expect(frame.enqueueTimeMicros == 1_000_500)
        #expect(frame.presentationTimeMicros == 1_001_000)
        #expect(frame.rtpTimestamp == 90_000)
        #expect(frame.hdrActive)
        #expect(frame.colorspace == 2)
        #expect(frame.data.count == 0, "a null payload must map to an empty buffer, not a crash")
    }

    @Test("frame payload is exposed at its real length")
    func framePayloadMapping() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65, 0xAA]
        bytes.withUnsafeBytes { raw in
            var c = MysticFrame()
            c.data = raw.bindMemory(to: UInt8.self).baseAddress
            c.data_len = bytes.count

            let frame = VideoFrameInfo(c)
            #expect(frame.data.count == bytes.count)
            #expect(Array(frame.data) == bytes)
        }
    }

    @Test("dispositions map to the values the C callback returns")
    func dispositionCodes() {
        #expect(FrameDisposition.ok.callbackCode == 0)
        #expect(FrameDisposition.needIDR.callbackCode == 1)
    }

    @Test("a video consumer can be implemented and driven")
    func consumerIsUsable() throws {
        final class Recorder: VideoConsumer {
            var setups: [VideoSetupInfo] = []
            var started = false
            var frames: [UInt32] = []
            var disposition: FrameDisposition = .ok

            func setup(_ info: VideoSetupInfo) throws { setups.append(info) }
            func start() { started = true }
            func submit(_ frame: VideoFrameInfo) -> FrameDisposition {
                frames.append(frame.number)
                return disposition
            }
            func stop() {}
            func cleanup() {}
        }

        let recorder = Recorder()
        try recorder.setup(VideoSetupInfo(format: 1, width: 2560, height: 1440, fps: 120))
        recorder.start()

        var c = MysticFrame()
        c.number = 7
        // A borrowed buffer with the same shape the engine hands over.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4, alignment: 1)
        defer { buffer.deallocate() }
        c.data = UnsafePointer(buffer.bindMemory(to: UInt8.self).baseAddress)
        c.data_len = 4
        _ = recorder.submit(VideoFrameInfo(c))

        #expect(recorder.setups.count == 1)
        #expect(recorder.setups.first?.width == 2560)
        #expect(recorder.started)
        #expect(recorder.frames == [7])
    }
}
