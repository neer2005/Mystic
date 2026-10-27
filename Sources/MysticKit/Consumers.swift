import CMystic

/// What the host negotiated for the video stream.
public struct VideoSetupInfo: Sendable, Equatable {
    /// `VIDEO_FORMAT_*` from the header.
    public var format: UInt32
    public var width: Int32
    public var height: Int32
    public var fps: Int32
    public var chromaPacking: UInt8
    public var logicalWidth: Int32
    public var logicalHeight: Int32
    public var colorSpace: Int32
    public var colorRange: Int32

    public init(
        format: UInt32,
        width: Int32,
        height: Int32,
        fps: Int32,
        chromaPacking: UInt8 = 0,
        logicalWidth: Int32 = 0,
        logicalHeight: Int32 = 0,
        colorSpace: Int32 = 0,
        colorRange: Int32 = 0
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.fps = fps
        self.chromaPacking = chromaPacking
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.colorSpace = colorSpace
        self.colorRange = colorRange
    }
}

/// A frame handed to the decoder.
///
/// `data` borrows engine memory and is valid **only** for the duration of the call. A decoder
/// that keeps the bytes past the callback must copy them.
public struct VideoFrameInfo {
    public var number: UInt32
    public var isKeyFrame: Bool
    /// Host-reported processing latency in 1/10 ms; zero when the host does not report it.
    public var hostProcessingLatencyTenthMs: UInt16
    public var receiveTimeMicros: UInt64
    public var enqueueTimeMicros: UInt64
    public var presentationTimeMicros: UInt64
    public var rtpTimestamp: UInt32
    public var hdrActive: Bool
    public var colorspace: UInt8
    public var data: UnsafeRawBufferPointer

    public init(
        number: UInt32,
        isKeyFrame: Bool,
        hostProcessingLatencyTenthMs: UInt16,
        receiveTimeMicros: UInt64,
        enqueueTimeMicros: UInt64,
        presentationTimeMicros: UInt64,
        rtpTimestamp: UInt32,
        hdrActive: Bool,
        colorspace: UInt8,
        data: UnsafeRawBufferPointer
    ) {
        self.number = number
        self.isKeyFrame = isKeyFrame
        self.hostProcessingLatencyTenthMs = hostProcessingLatencyTenthMs
        self.receiveTimeMicros = receiveTimeMicros
        self.enqueueTimeMicros = enqueueTimeMicros
        self.presentationTimeMicros = presentationTimeMicros
        self.rtpTimestamp = rtpTimestamp
        self.hdrActive = hdrActive
        self.colorspace = colorspace
        self.data = data
    }
}

/// What the decoder wants the engine to do next.
public enum FrameDisposition: Sendable, Equatable {
    case ok
    /// The decoder could not use the frame and needs a key frame to resynchronise.
    case needIDR
}

/// A video sink the engine pushes frames into.
///
/// Calls arrive on an engine-owned thread and may overlap with audio and log callbacks, so an
/// implementation is responsible for serialising its own work. Throwing from ``setup(_:)``
/// fails the video stage and aborts the connection, which is what you want when the host
/// negotiates a codec the decoder cannot handle.
public protocol VideoConsumer: AnyObject {
    func setup(_ info: VideoSetupInfo) throws
    func start()
    func submit(_ frame: VideoFrameInfo) -> FrameDisposition
    func stop()
    func cleanup()
}

/// What the host negotiated for audio.
public struct AudioSetupInfo: Sendable, Equatable {
    public var channelCount: UInt8
    public var channelMask: UInt16
    public var packetDurationMs: UInt32
    public var samplesPerFrame: UInt32

    public init(channelCount: UInt8, channelMask: UInt16, packetDurationMs: UInt32, samplesPerFrame: UInt32) {
        self.channelCount = channelCount
        self.channelMask = channelMask
        self.packetDurationMs = packetDurationMs
        self.samplesPerFrame = samplesPerFrame
    }
}

/// An audio sink the engine pushes Opus packets into.
public protocol AudioConsumer: AnyObject {
    func setup(_ info: AudioSetupInfo) throws
    func start()
    /// `packet` is nil for a lost packet, where the renderer should conceal the gap.
    func play(_ packet: UnsafeRawBufferPointer?)
    func stop()
    func cleanup()
}

// MARK: - Mapping from the C ABI

// These are internal on purpose: they are the field-by-field translation the callbacks use,
// kept as named initialisers so a swapped or forgotten field is a test failure rather than a
// stream that renders at the wrong size.
extension VideoSetupInfo {
    init(_ cValue: MysticVideoSetup) {
        self.init(
            format: cValue.format,
            width: cValue.width,
            height: cValue.height,
            fps: cValue.fps,
            chromaPacking: cValue.chroma_packing,
            logicalWidth: cValue.logical_width,
            logicalHeight: cValue.logical_height,
            colorSpace: cValue.color_space,
            colorRange: cValue.color_range
        )
    }
}

extension AudioSetupInfo {
    init(_ cValue: MysticAudioSetup) {
        self.init(
            channelCount: cValue.channel_count,
            channelMask: cValue.channel_mask,
            packetDurationMs: cValue.packet_duration_ms,
            samplesPerFrame: cValue.samples_per_frame
        )
    }
}

extension VideoFrameInfo {
    /// Copies a frame out of the ABI. `data` still borrows engine memory: the caller must use
    /// it before the callback returns.
    init(_ cValue: MysticFrame) {
        self.init(
            number: cValue.number,
            isKeyFrame: cValue.frame_type == 1,
            hostProcessingLatencyTenthMs: cValue.host_processing_latency,
            receiveTimeMicros: cValue.receive_time_us,
            enqueueTimeMicros: cValue.enqueue_time_us,
            presentationTimeMicros: cValue.presentation_time_us,
            rtpTimestamp: cValue.rtp_timestamp,
            hdrActive: cValue.hdr_active,
            colorspace: cValue.colorspace,
            data: UnsafeRawBufferPointer(
                start: cValue.data,
                count: cValue.data == nil ? 0 : cValue.data_len
            )
        )
    }
}

extension FrameDisposition {
    /// The value the C callback must return.
    var callbackCode: Int32 {
        switch self {
        case .ok: 0
        case .needIDR: 1
        }
    }
}
