//! C ABI over Nightjar's `nightjar-core` streaming engine.
//!
//! Why this crate exists: `nightjar-core` exposes Rust traits (`VideoDecoder`,
//! `AudioRenderer`, `Listener`) which a Swift app cannot implement. This crate turns
//! those traits into C function pointers and keeps every Rust type behind an opaque
//! handle, so the Swift side only ever sees plain data.
//!
//! Threading contract, which the caller must respect:
//!
//! - `mystic_session_start` **blocks** until the stream is running or a stage fails.
//!   Call it off the main thread.
//! - Video, audio and listener callbacks arrive on session-owned threads, never on the
//!   thread that called `start` (except stage events during `start`). They may be called
//!   concurrently with each other; the `user` pointer must be safe for that.
//! - `mystic_session_interrupt` may be called from any thread while `start` blocks.
//! - `mystic_session_free` tears the session down and must not race with a callback;
//!   stop the session first and release the handle from the owning thread.
//!
//! Panics: the crate is built with `panic = "abort"` in release, so no unwinding ever
//! crosses the C boundary; a bug aborts rather than corrupting the caller.

mod host;
mod files;
mod folders;
mod wake;
mod audio;
mod microphone;
mod policy;
mod controller_feedback;
mod clipboard;
mod rates;
mod health;
mod clock;
mod display;
mod phase;
mod timing_csv;
mod quality;
mod cursor;
mod keyboard;
mod diagnostics;

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, Mutex};

use nightjar_core::input::{packets::MAX_CONTROLLERS, InputError, InputQueue};
use nightjar_core::sdp::{AudioConfiguration, StreamConfig, StreamLocation};
use nightjar_core::session::{
    AudioRenderer, AudioSetup, DecodeStatus, HostInfo, Interrupt, Listener, Session, SessionConfig,
    Stage, VideoDecoder, VideoSetup,
};
use nightjar_core::video::{Frame, FrameType};

/// Bumped whenever a struct layout or function signature changes. The Swift side refuses
/// to run against a mismatch rather than misreading memory.
pub const MYSTIC_ABI_VERSION: u32 = 5;

// ---------------------------------------------------------------------------
// Result codes
// ---------------------------------------------------------------------------

pub const MYSTIC_OK: i32 = 0;
pub const MYSTIC_ERR_INVALID_ARGUMENT: i32 = -1;
pub const MYSTIC_ERR_START_FAILED: i32 = -2;
pub const MYSTIC_ERR_NOT_STARTED: i32 = -3;
pub const MYSTIC_ERR_BUFFER_TOO_SMALL: i32 = -4;
pub const MYSTIC_ERR_UNIMPLEMENTED: i32 = -5;
pub const MYSTIC_ERR_INPUT_FAILED: i32 = -6;

// ---------------------------------------------------------------------------
// Plain data mirroring the engine's types
// ---------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MysticVideoSetup {
    /// `VIDEO_FORMAT_*`.
    pub format: u32,
    pub width: i32,
    pub height: i32,
    pub fps: i32,
    pub chroma_packing: u8,
    pub logical_width: i32,
    pub logical_height: i32,
    pub color_space: i32,
    pub color_range: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MysticAudioSetup {
    pub channel_count: u8,
    pub channel_mask: u16,
    pub packet_duration_ms: u32,
    pub samples_per_frame: u32,
    pub sample_rate: u32,
    pub streams: u8,
    pub coupled_streams: u8,
    pub mapping: [u8; 8],
}

/// Borrowed view of one completed frame. `data` points into engine memory and is valid
/// only for the duration of the `submit` call — copy what you need.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MysticFrame {
    pub number: u32,
    /// 0 = P, 1 = IDR.
    pub frame_type: u8,
    /// Host processing latency in 1/10 ms; zero when the host does not report it.
    pub host_processing_latency: u16,
    pub receive_time_us: u64,
    pub enqueue_time_us: u64,
    pub presentation_time_us: u64,
    pub rtp_timestamp: u32,
    pub hdr_active: bool,
    pub colorspace: u8,
    pub data: *const u8,
    pub data_len: usize,
    pub buffer_count: usize,
}

/// One buffer inside a frame, a range of `MysticFrame::data`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MysticFrameBuffer {
    /// `BUFFER_TYPE_*` (0 = picture data, others are parameter sets).
    pub kind: u8,
    pub offset: usize,
    pub length: usize,
}

/// The negotiated stream configuration, flattened for C.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MysticStreamConfig {
    pub width: i32,
    pub height: i32,
    pub fps: i32,
    pub bitrate_kbps: i32,
    pub packet_size: i32,
    /// `VIDEO_FORMAT_*` the decoder accepts.
    pub supported_video_formats: u32,
    pub video_capabilities: u32,
    pub audio_capabilities: u32,
    pub encryption_flags: u32,
    pub color_space: i32,
    pub color_range: i32,
    pub client_refresh_rate_x100: i32,
    pub channel_count: u8,
    pub channel_mask: u16,
    pub microphone: bool,
    pub haptics_pcm: bool,
    pub experimental_packed_444: bool,
    pub packed444_modes: u8,
    pub pyrowave_records_supported: bool,
    pub pyrowave_row_order: bool,
    pub client_wireless: bool,
    /// The `rikey` from launch; also the encrypted RTSP key.
    pub remote_input_aes_key: [u8; 16],
    pub remote_input_aes_iv: [u8; 16],
    /// How long the stream rides out network silence, in milliseconds (Nightjar's "Ride out
    /// network drops"); at or below the control connection's own 10 s it adds no tolerance.
    pub network_grace_ms: u32,
    /// The video FEC to ask a Sunshine-based host for in the ANNOUNCE: `MYSTIC_FEC_HOST`,
    /// `MYSTIC_FEC_AUTO`, or a fixed percentage 0-255. Rubylight hosts take it at launch.
    pub video_fec: i16,
    /// This Mac's wired link speed toward the host in Mbit/s; 0 on Wi-Fi or when unknown.
    pub link_mbps: i32,
    /// `MYSTIC_LOCATION_*`. Auto decides from the address; a VPN route is streamed as remote.
    pub location: u8,
    /// Client roaming (Nightjar's default on): move the stream onto a new network, with hosts
    /// that advertise it.
    pub client_roaming: bool,
    /// "Continue on mobile data": roam onto a metered network too.
    pub roaming_metered: bool,
    /// The app reports every network change with `mystic_session_network_changed`.
    pub network_hints: bool,
}

pub const MYSTIC_LOCATION_AUTO: u8 = 0;
pub const MYSTIC_LOCATION_LOCAL: u8 = 1;
pub const MYSTIC_LOCATION_REMOTE: u8 = 2;

/// `MysticStreamConfig::video_fec`: the host's own error correction.
pub const MYSTIC_FEC_HOST: i16 = -1;
/// `MysticStreamConfig::video_fec`: error correction that follows this client's loss reports.
pub const MYSTIC_FEC_AUTO: i16 = -2;

/// The FEC choice a `video_fec` value names; anything unrecognised leaves it to the host.
pub fn fec_choice(value: i16) -> rubylight_protocol::fec_report::FecChoice {
    use rubylight_protocol::fec_report::FecChoice;
    match value {
        MYSTIC_FEC_AUTO => FecChoice::Auto,
        0..=255 => FecChoice::Fixed(value as u8),
        _ => FecChoice::Host,
    }
}

impl Default for MysticStreamConfig {
    fn default() -> Self {
        let base = StreamConfig::default();
        Self {
            width: base.width,
            height: base.height,
            fps: base.fps,
            bitrate_kbps: base.bitrate_kbps,
            packet_size: base.packet_size,
            supported_video_formats: base.supported_video_formats,
            video_capabilities: 0,
            audio_capabilities: 0,
            encryption_flags: base.encryption_flags,
            color_space: base.color_space,
            color_range: base.color_range,
            client_refresh_rate_x100: 0,
            channel_count: 2,
            channel_mask: 0x3,
            microphone: false,
            haptics_pcm: false,
            experimental_packed_444: false,
            packed444_modes: 0,
            pyrowave_records_supported: false,
            pyrowave_row_order: false,
            client_wireless: false,
            remote_input_aes_key: [0; 16],
            remote_input_aes_iv: [0; 16],
            network_grace_ms: 0,
            video_fec: MYSTIC_FEC_HOST,
            link_mbps: 0,
            location: MYSTIC_LOCATION_AUTO,
            client_roaming: false,
            roaming_metered: false,
            network_hints: false,
        }
    }
}

impl MysticStreamConfig {
    /// As Nightjar's desktop `session_config`: without hints the session cannot tell which
    /// networks are metered, so roaming then needs "Continue on mobile data" too.
    fn session(&self) -> SessionConfig {
        use nightjar_core::session::{Location, RoamingConfig};
        SessionConfig {
            stream: self.to_engine(),
            location: match self.location {
                MYSTIC_LOCATION_LOCAL => Location::Local,
                MYSTIC_LOCATION_REMOTE => Location::Remote,
                _ => Location::Auto,
            },
            network_grace: std::time::Duration::from_millis(u64::from(self.network_grace_ms)),
            roaming: RoamingConfig {
                enabled: self.client_roaming && (self.network_hints || self.roaming_metered),
                metered: self.roaming_metered,
                platform_hints: self.network_hints,
            },
            ..SessionConfig::default()
        }
    }
    fn to_engine(&self) -> StreamConfig {
        StreamConfig {
            width: self.width,
            height: self.height,
            fps: self.fps,
            bitrate_kbps: self.bitrate_kbps,
            packet_size: self.packet_size,
            location: StreamLocation::Local,
            audio: AudioConfiguration {
                channel_count: self.channel_count,
                channel_mask: self.channel_mask,
            },
            supported_video_formats: self.supported_video_formats,
            experimental_packed_444: self.experimental_packed_444,
            packed444_modes: self.packed444_modes,
            client_refresh_rate_x100: self.client_refresh_rate_x100,
            color_space: self.color_space,
            color_range: self.color_range,
            encryption_flags: self.encryption_flags,
            remote_input_aes_key: self.remote_input_aes_key,
            remote_input_aes_iv: self.remote_input_aes_iv,
            video_capabilities: self.video_capabilities,
            audio_capabilities: self.audio_capabilities,
            // ABI 2 carries Opus configuration only; passthrough needs a new ABI.
            audio_passthrough: 0,
            haptics_pcm: self.haptics_pcm,
            microphone: self.microphone,
            pyrowave_records_supported: self.pyrowave_records_supported,
            pyrowave_row_order: self.pyrowave_row_order,
            client_wireless: self.client_wireless,
            pyrowave_link_mbps: self.link_mbps.max(0),
            video_fec: fec_choice(self.video_fec),
            ..StreamConfig::default()
        }
    }
}

/// Stage event kinds delivered to `MysticCallbacks::stage`.
pub const MYSTIC_STAGE_STARTING: i32 = 0;
pub const MYSTIC_STAGE_COMPLETE: i32 = 1;
pub const MYSTIC_STAGE_FAILED: i32 = 2;

/// Callback table. Any callback may be null; a null video `submit` drops frames, which is
/// useful for connection-only work.
///
/// `user` is passed back unchanged and is never dereferenced by Rust.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MysticCallbacks {
    pub user: *mut c_void,

    /// Return 0 to proceed, non-zero to fail the video stage with that code.
    pub video_setup:
        Option<unsafe extern "C" fn(user: *mut c_void, setup: *const MysticVideoSetup) -> i32>,
    pub video_start: Option<unsafe extern "C" fn(user: *mut c_void)>,
    /// Return 0 for `Ok`, 1 for `NeedIdr`.
    pub video_submit:
        Option<unsafe extern "C" fn(user: *mut c_void, frame: *const MysticFrame) -> i32>,
    pub video_stop: Option<unsafe extern "C" fn(user: *mut c_void)>,
    pub video_cleanup: Option<unsafe extern "C" fn(user: *mut c_void)>,

    /// Return 0 to proceed, non-zero to fail the audio stage with that code.
    pub audio_init:
        Option<unsafe extern "C" fn(user: *mut c_void, setup: *const MysticAudioSetup) -> i32>,
    pub audio_start: Option<unsafe extern "C" fn(user: *mut c_void)>,
    /// `packet` is null for a lost packet: run packet loss concealment.
    pub audio_play: Option<unsafe extern "C" fn(user: *mut c_void, packet: *const u8, len: usize)>,
    pub audio_stop: Option<unsafe extern "C" fn(user: *mut c_void)>,
    pub audio_cleanup: Option<unsafe extern "C" fn(user: *mut c_void)>,

    /// `event` is one of `MYSTIC_STAGE_*`; `error` is the stage code when it failed.
    pub stage: Option<unsafe extern "C" fn(user: *mut c_void, stage: i32, event: i32, error: i32)>,
    pub connection_started: Option<unsafe extern "C" fn(user: *mut c_void)>,
    pub connection_terminated: Option<unsafe extern "C" fn(user: *mut c_void, code: i32)>,
    /// NUL-terminated UTF-8, borrowed for the duration of the call.
    pub log: Option<unsafe extern "C" fn(user: *mut c_void, message: *const c_char)>,
}

// The callbacks table is read-only after `start` and the user pointer's thread safety is
// the caller's contract (see the crate docs).
unsafe impl Send for MysticCallbacks {}
unsafe impl Sync for MysticCallbacks {}

// ---------------------------------------------------------------------------
// Trait adapters: Rust traits -> C function pointers
// ---------------------------------------------------------------------------

struct VideoAdapter {
    callbacks: MysticCallbacks,
    submitted: u64,
    network: Arc<Mutex<policy::NetworkTiming>>,
}

impl VideoDecoder for VideoAdapter {
    fn setup(&mut self, setup: &VideoSetup) -> Result<(), i32> {
        self.network.lock().unwrap_or_else(|e| e.into_inner()).setup(
            setup.format, setup.width.max(0) as u32, setup.height.max(0) as u32, setup.fps.max(0) as u32);
        let plain = MysticVideoSetup {
            format: setup.format,
            width: setup.width,
            height: setup.height,
            fps: setup.fps,
            chroma_packing: setup.chroma_packing,
            logical_width: setup.logical_width,
            logical_height: setup.logical_height,
            color_space: setup.color_space,
            color_range: setup.color_range,
        };
        match self.callbacks.video_setup {
            Some(f) => match unsafe { f(self.callbacks.user, &plain) } {
                0 => Ok(()),
                code => Err(code),
            },
            None => Ok(()),
        }
    }

    fn start(&mut self) {
        if let Some(f) = self.callbacks.video_start {
            unsafe { f(self.callbacks.user) }
        }
    }

    fn submit(&mut self, frame: &Frame) -> DecodeStatus {
        {
            let mut network = self.network.lock().unwrap_or_else(|e| e.into_inner());
            network.frame(frame.rtp_timestamp, frame.receive_time_us, u32::from(frame.host_processing_latency) * 100);
            network.received_bytes += frame.data().len() as u64;
        }
        let Some(f) = self.callbacks.video_submit else {
            return DecodeStatus::Ok;
        };
        let data = frame.data();
        let plain = MysticFrame {
            number: frame.number,
            frame_type: match frame.frame_type {
                FrameType::Idr => 1,
                FrameType::P => 0,
            },
            host_processing_latency: frame.host_processing_latency,
            receive_time_us: frame.receive_time_us,
            enqueue_time_us: frame.enqueue_time_us,
            presentation_time_us: frame.presentation_time_us,
            rtp_timestamp: frame.rtp_timestamp,
            hdr_active: frame.hdr_active,
            colorspace: frame.colorspace,
            data: data.as_ptr(),
            data_len: data.len(),
            buffer_count: frame.buffers().len(),
        };
        self.submitted += 1;
        match unsafe { f(self.callbacks.user, &plain) } {
            1 => DecodeStatus::NeedIdr,
            _ => DecodeStatus::Ok,
        }
    }

    fn stop(&mut self) {
        if let Some(f) = self.callbacks.video_stop {
            unsafe { f(self.callbacks.user) }
        }
    }

    fn cleanup(&mut self) {
        if let Some(f) = self.callbacks.video_cleanup {
            unsafe { f(self.callbacks.user) }
        }
    }
}

struct AudioAdapter {
    callbacks: MysticCallbacks,
}

impl AudioRenderer for AudioAdapter {
    fn init(&mut self, setup: &AudioSetup) -> Result<(), i32> {
        // Nightjar supports 12-channel audio; ABI 2 and the Swift renderer support up to 8.
        // Never truncate an active channel or feed passthrough packets to the Opus decoder.
        if setup.codec != rubylight_protocol::audio_ext::CODEC_OPUS
            || !matches!(setup.configuration.channel_count, 2 | 6 | 8)
            || setup.opus.channel_count != setup.configuration.channel_count
        {
            return Err(MYSTIC_ERR_UNIMPLEMENTED);
        }
        let mut mapping = [0; 8];
        mapping.copy_from_slice(&setup.opus.mapping[..8]);
        let plain = MysticAudioSetup {
            channel_count: setup.configuration.channel_count,
            channel_mask: setup.configuration.channel_mask,
            packet_duration_ms: setup.packet_duration_ms,
            samples_per_frame: setup.samples_per_frame,
            sample_rate: setup.opus.sample_rate,
            streams: setup.opus.streams,
            coupled_streams: setup.opus.coupled_streams,
            mapping,
        };
        match self.callbacks.audio_init {
            Some(f) => match unsafe { f(self.callbacks.user, &plain) } {
                0 => Ok(()),
                code => Err(code),
            },
            None => Ok(()),
        }
    }

    fn start(&mut self) {
        if let Some(f) = self.callbacks.audio_start {
            unsafe { f(self.callbacks.user) }
        }
    }

    fn play(&mut self, packet: Option<&[u8]>) {
        let Some(f) = self.callbacks.audio_play else {
            return;
        };
        match packet {
            Some(bytes) => unsafe { f(self.callbacks.user, bytes.as_ptr(), bytes.len()) },
            None => unsafe { f(self.callbacks.user, std::ptr::null(), 0) },
        }
    }

    fn stop(&mut self) {
        if let Some(f) = self.callbacks.audio_stop {
            unsafe { f(self.callbacks.user) }
        }
    }

    fn cleanup(&mut self) {
        if let Some(f) = self.callbacks.audio_cleanup {
            unsafe { f(self.callbacks.user) }
        }
    }
}

struct ListenerAdapter {
    callbacks: MysticCallbacks,
    feedback: Arc<Mutex<controller_feedback::FeedbackMailbox>>,
    clipboard: Arc<Mutex<clipboard::ClipboardState>>,
    rates: Arc<Mutex<rates::Rates>>,
    display: Arc<Mutex<display::DisplayReports>>,
    phase: Arc<Mutex<phase::PhaseReports>>,
    clock: Arc<Mutex<clock::ClockSync>>,
    timing: Arc<Mutex<timing_csv::TimingOutput>>,
    cursor: Arc<Mutex<cursor::CursorQueue>>,
    text_fields: Arc<Mutex<keyboard::TextFields>>,
    reconfigure: Arc<std::sync::atomic::AtomicBool>,
}

impl ListenerAdapter {
    fn emit_stage(&self, stage: Stage, event: i32, error: i32) {
        if let Some(f) = self.callbacks.stage {
            unsafe { f(self.callbacks.user, stage as i32, event, error) }
        }
    }

    fn emit_log(&self, message: &str) {
        if let Some(f) = self.callbacks.log {
            if let Ok(c) = CString::new(message) {
                unsafe { f(self.callbacks.user, c.as_ptr()) }
            }
        }
    }
}

impl Listener for ListenerAdapter {
    fn host_control_messages(&self, messages: &[u16]) {
        self.clipboard.lock().unwrap_or_else(|e| e.into_inner()).announce(messages);
        self.rates.lock().unwrap_or_else(|e|e.into_inner()).announce(messages);
        self.display.lock().unwrap_or_else(|e| e.into_inner()).announce(messages);
        self.phase.lock().unwrap_or_else(|e| e.into_inner()).announce(messages);
        self.clock.lock().unwrap_or_else(|e| e.into_inner()).announce(messages);
        self.timing.lock().unwrap_or_else(|e| e.into_inner()).announce(messages);
        self.reconfigure.store(messages.contains(&rubylight_protocol::control::RECONFIGURE_MESSAGE_TYPE), std::sync::atomic::Ordering::Release);
    }
    fn control_event(&self, event: nightjar_core::control::ControlEvent) {
        if matches!(event,nightjar_core::control::ControlEvent::RateChange(_)) {
            self.rates.lock().unwrap_or_else(|e|e.into_inner()).receive(event);return;
        }
        if let nightjar_core::control::ControlEvent::HostTiming(records) = &event {
            if let Some(csv) = &self.timing.lock().unwrap_or_else(|e| e.into_inner()).csv { csv.reports(records); }
            return;
        }
        if matches!(event, nightjar_core::control::ControlEvent::ClockSync { .. }) {
            self.clock.lock().unwrap_or_else(|e| e.into_inner()).receive(event);
            return;
        }
        if matches!(event, nightjar_core::control::ControlEvent::ClipboardSync(_)) {
            self.clipboard.lock().unwrap_or_else(|e| e.into_inner()).receive(event);
            return;
        }
        if matches!(event, nightjar_core::control::ControlEvent::CursorShape(_)
            | nightjar_core::control::ControlEvent::CursorShapeRejected(_)) {
            self.cursor.lock().unwrap_or_else(|e| e.into_inner()).receive(event);
            return;
        }
        if matches!(event, nightjar_core::control::ControlEvent::TextInput(_)) {
            self.text_fields.lock().unwrap_or_else(|e| e.into_inner()).receive(event);
            return;
        }
        if matches!(event, nightjar_core::control::ControlEvent::Rumble { .. }
            | nightjar_core::control::ControlEvent::RumbleTriggers { .. }
            | nightjar_core::control::ControlEvent::SetControllerLed { .. }
            | nightjar_core::control::ControlEvent::SetMotionEventState { .. }) {
            self.feedback.lock().unwrap_or_else(|e| e.into_inner()).receive(event);
        }
    }

    fn stage_starting(&self, stage: Stage) {
        self.emit_stage(stage, MYSTIC_STAGE_STARTING, 0);
    }

    fn stage_complete(&self, stage: Stage) {
        self.emit_stage(stage, MYSTIC_STAGE_COMPLETE, 0);
    }

    fn stage_failed(&self, stage: Stage, error: i32) {
        self.emit_stage(stage, MYSTIC_STAGE_FAILED, error);
        self.emit_log(&format!("stage {stage:?} failed with {error}"));
    }

    fn connection_started(&self) {
        if let Some(f) = self.callbacks.connection_started {
            unsafe { f(self.callbacks.user) }
        }
    }

    fn connection_terminated(&self, code: i32) {
        if let Some(f) = self.callbacks.connection_terminated {
            unsafe { f(self.callbacks.user, code) }
        }
    }

    fn log(&self, message: &str) {
        self.emit_log(message);
    }
}

// ---------------------------------------------------------------------------
// Handle
// ---------------------------------------------------------------------------

/// Opaque session handle. Never dereferenced by the caller.
pub struct MysticSession {
    session: Option<Session>,
    interrupt: Interrupt,
    last_error: Option<CString>,
    network: Arc<Mutex<policy::NetworkTiming>>,
    bitrate: Option<policy::Bitrate>,
    feedback: Arc<Mutex<controller_feedback::FeedbackMailbox>>,
    clipboard: Arc<Mutex<clipboard::ClipboardState>>,
    rates: Arc<Mutex<rates::Rates>>,
    display: Arc<Mutex<display::DisplayReports>>,
    phase: Arc<Mutex<phase::PhaseReports>>,
    clock: Arc<Mutex<clock::ClockSync>>,
    timing: Arc<Mutex<timing_csv::TimingOutput>>,
    cursor: Arc<Mutex<cursor::CursorQueue>>,
    text_fields: Arc<Mutex<keyboard::TextFields>>,
    doctor: health::Doctor,
    /// The host takes Reconfigure (0x5532), for automatic quality.
    reconfigure: Arc<std::sync::atomic::AtomicBool>,
    quality: Option<quality::Quality>,
    /// The doctor's latest sample, for the quality tick of the same second.
    last_tick: Option<nightjar_policy::stats::Stats>,
}

fn write_error(buffer: *mut c_char, capacity: usize, message: &str) {
    if buffer.is_null() || capacity == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let take = bytes.len().min(capacity - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, take);
        *buffer.add(take) = 0;
    }
}

/// Sizes of every struct crossing the boundary, as Rust laid them out. The C header exposes
/// the same struct, so the C test can prove the two definitions agree instead of trusting a
/// hand-checked constant.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MysticStructSizes {
    pub video_setup: usize,
    pub audio_setup: usize,
    pub frame: usize,
    pub frame_buffer: usize,
    pub stream_config: usize,
    pub callbacks: usize,
}

#[no_mangle]
pub extern "C" fn mystic_struct_sizes() -> MysticStructSizes {
    MysticStructSizes {
        video_setup: std::mem::size_of::<MysticVideoSetup>(),
        audio_setup: std::mem::size_of::<MysticAudioSetup>(),
        frame: std::mem::size_of::<MysticFrame>(),
        frame_buffer: std::mem::size_of::<MysticFrameBuffer>(),
        stream_config: std::mem::size_of::<MysticStreamConfig>(),
        callbacks: std::mem::size_of::<MysticCallbacks>(),
    }
}

#[no_mangle]
pub extern "C" fn mystic_abi_version() -> u32 {
    MYSTIC_ABI_VERSION
}

/// Creates an empty handle. Free it with `mystic_session_free`.
#[no_mangle]
pub extern "C" fn mystic_session_new() -> *mut MysticSession {
    Box::into_raw(Box::new(MysticSession {
        session: None,
        interrupt: Interrupt::default(),
        last_error: None,
        network: Arc::new(Mutex::new(policy::NetworkTiming::default())),
        bitrate: None,
        feedback: Arc::new(Mutex::new(controller_feedback::FeedbackMailbox::default())),
        clipboard: Arc::new(Mutex::new(clipboard::ClipboardState::default())),
        rates: Arc::new(Mutex::new(rates::Rates::default())),
        display: Arc::new(Mutex::new(display::DisplayReports::default())),
        phase: Arc::new(Mutex::new(phase::PhaseReports::default())),
        clock: Arc::new(Mutex::new(clock::ClockSync::default())),
        timing: Arc::new(Mutex::new(timing_csv::TimingOutput::default())),
        cursor: Arc::new(Mutex::new(cursor::CursorQueue::default())),
        text_fields: Arc::new(Mutex::new(keyboard::TextFields::default())),
        reconfigure: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        quality: None,
        last_tick: None,
        doctor: health::Doctor::default(),
    }))
}

/// Tears down any running session and releases the handle. Null is a no-op.
///
/// # Safety
/// `handle` must come from `mystic_session_new` and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_free(handle: *mut MysticSession) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle));
}

/// Cancels a `mystic_session_start` that is still blocking. Thread-safe, callable from any
/// thread.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_interrupt(handle: *mut MysticSession) {
    if let Some(session) = handle.as_ref() {
        session.interrupt.interrupt();
    }
}

/// Connects and blocks until the stream runs or a stage fails.
///
/// `address` and `app_version` must be NUL-terminated UTF-8. `rtsp_session_url` may be null.
/// `error_buffer` receives a NUL-terminated message on failure and may be null.
///
/// # Safety
/// All pointers must be valid for the duration of the call; `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_start(
    handle: *mut MysticSession,
    address: *const c_char,
    app_version: *const c_char,
    rtsp_session_url: *const c_char,
    server_codec_mode_support: u32,
    config: *const MysticStreamConfig,
    callbacks: *const MysticCallbacks,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    let Some(handle) = handle.as_mut() else {
        write_error(error_buffer, error_capacity, "null session handle");
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    if address.is_null() || app_version.is_null() || config.is_null() {
        write_error(
            error_buffer,
            error_capacity,
            "address, app_version and config are required",
        );
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    if handle.session.is_some() {
        write_error(error_buffer, error_capacity, "session already started");
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    handle.bitrate = None;
    handle.doctor = health::Doctor::default();
    *handle.clipboard.lock().unwrap_or_else(|e| e.into_inner()) = clipboard::ClipboardState::default();
    *handle.rates.lock().unwrap_or_else(|e|e.into_inner()) = rates::Rates::default();
    *handle.feedback.lock().unwrap_or_else(|e| e.into_inner()) = controller_feedback::FeedbackMailbox::default();
    *handle.cursor.lock().unwrap_or_else(|e| e.into_inner()) = cursor::CursorQueue::default();
    *handle.text_fields.lock().unwrap_or_else(|e| e.into_inner()) = keyboard::TextFields::default();
    handle.quality = None;
    handle.last_tick = None;
    handle.reconfigure.store(false, std::sync::atomic::Ordering::Release);
    *handle.network.lock().unwrap_or_else(|e| e.into_inner()) = policy::NetworkTiming::default();

    let host_info = HostInfo {
        address: CStr::from_ptr(address).to_string_lossy().into_owned(),
        app_version: CStr::from_ptr(app_version).to_string_lossy().into_owned(),
        rtsp_session_url: if rtsp_session_url.is_null() {
            None
        } else {
            Some(
                CStr::from_ptr(rtsp_session_url)
                    .to_string_lossy()
                    .into_owned(),
            )
        },
        server_codec_mode_support,
    };

    let callbacks = if callbacks.is_null() {
        MysticCallbacks::default()
    } else {
        *callbacks
    };

    let session_config = (*config).session();

    let video: Box<dyn VideoDecoder> = Box::new(VideoAdapter {
        callbacks,
        submitted: 0,
        network: handle.network.clone(),
    });
    let audio: Box<dyn AudioRenderer> = Box::new(AudioAdapter { callbacks });
    let listener = Arc::new(ListenerAdapter { callbacks, feedback: handle.feedback.clone(), clipboard: handle.clipboard.clone(), rates:handle.rates.clone(), display: handle.display.clone(), phase: handle.phase.clone(), clock: handle.clock.clone(), timing: handle.timing.clone(), cursor: handle.cursor.clone(), text_fields: handle.text_fields.clone(), reconfigure: handle.reconfigure.clone() });

    match Session::start(
        &host_info,
        session_config,
        video,
        audio,
        listener,
        &handle.interrupt,
    ) {
        Ok(session) => {
            handle.session = Some(session);
            MYSTIC_OK
        }
        Err(error) => {
            let message = format!("{error:?}");
            write_error(error_buffer, error_capacity, &message);
            handle.last_error = CString::new(message).ok();
            MYSTIC_ERR_START_FAILED
        }
    }
}

/// Stops every stream. No termination callback is delivered afterwards. Idempotent.
///
/// # Safety
/// `handle` must be a live handle and no callback may still be running against it.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_stop(handle: *mut MysticSession) -> i32 {
    let Some(handle) = handle.as_mut() else {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    handle.bitrate = None;
    handle.doctor = health::Doctor::default();
    *handle.clipboard.lock().unwrap_or_else(|e| e.into_inner()) = clipboard::ClipboardState::default();
    *handle.rates.lock().unwrap_or_else(|e|e.into_inner()) = rates::Rates::default();
    *handle.feedback.lock().unwrap_or_else(|e| e.into_inner()) = controller_feedback::FeedbackMailbox::default();
    handle.quality = None;
    handle.last_tick = None;
    handle.reconfigure.store(false, std::sync::atomic::Ordering::Release);
    match handle.session.take() {
        Some(session) => {
            session.stop();
            MYSTIC_OK
        }
        None => MYSTIC_ERR_NOT_STARTED,
    }
}

/// Reserved: per-buffer descriptors (needed when a decoder wants parameter sets delivered
/// separately). Not implemented in ABI v1 — frames are submitted whole via
/// `MysticFrame::data`. Declared here so the symbol exists for the Swift binding.
///
/// # Safety
/// `frame` must be null or a frame pointer passed to `video_submit`.
#[no_mangle]
pub unsafe extern "C" fn mystic_frame_buffers(
    frame: *const MysticFrame,
    _out: *mut MysticFrameBuffer,
    _capacity: usize,
) -> i32 {
    if frame.is_null() {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    // Explicitly unimplemented rather than silently returning zero buffers: a caller that
    // asks gets a clear refusal instead of an empty result it might trust.
    MYSTIC_ERR_UNIMPLEMENTED
}

/// Input injection. All of these require a started session and return
/// `MYSTIC_ERR_NOT_STARTED` otherwise.
///
/// Calls are cheap and non-blocking: they enqueue into the engine's input queue, which
/// batches and paces delivery itself.
fn with_input(
    handle: *mut MysticSession,
    f: impl FnOnce(&mut InputQueue) -> Result<(), InputError>,
) -> i32 {
    // SAFETY: the handle contract is documented on every exported input function; a null
    // handle is handled here rather than dereferenced.
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    let Some(session) = handle.session.as_ref() else {
        return MYSTIC_ERR_NOT_STARTED;
    };
    match session.input(f) {
        Ok(()) => MYSTIC_OK,
        Err(_) => MYSTIC_ERR_INPUT_FAILED,
    }
}

/// As `with_input`, for extras a host may not take: refusal is not an input failure.
fn with_optional_input(
    handle: *mut MysticSession,
    f: impl FnOnce(&mut InputQueue) -> Result<(), InputError>,
) -> i32 {
    let mut unsupported = false;
    let result = with_input(handle, |q| match f(q) {
        Err(InputError::Unsupported) => { unsupported = true; Ok(()) }
        other => other,
    });
    if unsupported { MYSTIC_ERR_UNIMPLEMENTED } else { result }
}

/// Relative mouse motion.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_mouse_move(
    handle: *mut MysticSession,
    dx: i16,
    dy: i16,
) -> i32 {
    with_input(handle, |q| q.send_mouse_move(dx, dy))
}

/// Absolute mouse position in host coordinates (`0..width`, `0..height`).
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_mouse_position(
    handle: *mut MysticSession,
    x: i16,
    y: i16,
    width: i16,
    height: i16,
) -> i32 {
    with_input(handle, |q| q.send_mouse_position(x, y, width, height))
}

/// Mouse button state. Button numbering follows the host's HID buttons.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_mouse_button(
    handle: *mut MysticSession,
    button: u8,
    down: bool,
) -> i32 {
    with_input(handle, |q| q.send_mouse_button(button, down))
}

/// Keyboard event. `key_code` is a Windows virtual-key code; `modifiers` and `flags` are the
/// engine's modifier bits and event flags.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_keyboard(
    handle: *mut MysticSession,
    key_code: u16,
    down: bool,
    modifiers: u8,
    flags: u8,
) -> i32 {
    with_input(handle, |q| {
        q.send_keyboard(key_code, down, modifiers, flags)
    })
}

/// Vertical scroll in whole clicks (positive = up).
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_scroll(handle: *mut MysticSession, clicks: i8) -> i32 {
    with_input(handle, |q| q.send_scroll(clicks))
}

/// Vertical scroll in 1/120 of a click, for trackpads and smooth wheels.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_high_res_scroll(
    handle: *mut MysticSession,
    amount: i16,
) -> i32 {
    with_input(handle, |q| q.send_high_res_scroll(amount))
}

/// Asks the host for a key frame, e.g. after the decoder reported `NeedIdr`.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_request_idr(handle: *mut MysticSession) -> i32 {
    let Some(handle) = handle.as_ref() else {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    let Some(session) = handle.session.as_ref() else {
        return MYSTIC_ERR_NOT_STARTED;
    };
    session.request_idr_frame();
    MYSTIC_OK
}

/// Horizontal scroll in 1/120 of a click. The caller must hold a live session handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_horizontal_scroll(handle: *mut MysticSession, amount: i16) -> i32 {
    with_input(handle, |q| q.send_high_res_hscroll(amount))
}

/// Full controller state. Caller serializes input and owns a live session handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_controller(handle: *mut MysticSession, slot: u8, mask: u16,
    buttons: u32, lt: u8, rt: u8, lx: i16, ly: i16, rx: i16, ry: i16) -> i32 {
    if slot >= MAX_CONTROLLERS || buttons & !controller_buttons::KNOWN != 0 { return MYSTIC_ERR_INVALID_ARGUMENT; }
    with_input(handle, |q| q.send_controller(u16::from(slot), mask, buttons, lt, rt, (lx, ly), (rx, ry)))
}

/// Compatibility entry point: generic extended gamepad without feedback.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_controller_arrival(handle: *mut MysticSession, slot: u8, mask: u16) -> i32 {
    mystic_session_controller_arrival_with_feedback(handle, slot, mask, 0x01, 0)
}

/// ABI 2 entry point: an unknown controller type with the classic buttons.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_controller_arrival_with_feedback(
    handle: *mut MysticSession, slot: u8, mask: u16, capabilities: u16, epoch: u64,
) -> i32 {
    mystic_session_controller_announce(handle, slot, mask, 0, controller_buttons::CLASSIC, capabilities, epoch)
}

/// Bits Mystic delivers: what the controller has and what the Mac sends for it.
mod controller_buttons {
    use nightjar_core::input::packets::button::*;
    pub const CLASSIC: u32 = UP | DOWN | LEFT | RIGHT | PLAY | BACK | LS_CLK | RS_CLK | LB | RB | A | B | X | Y;
    pub const KNOWN: u32 = CLASSIC | SPECIAL | PADDLE1 | PADDLE2 | PADDLE3 | PADDLE4 | TOUCHPAD | MISC;
}
fn delivered_capabilities() -> u16 {
    use nightjar_core::input::packets::capability::*;
    ANALOG_TRIGGERS | RUMBLE | TRIGGER_RUMBLE | ACCEL | GYRO | BATTERY_STATE | RGB_LED
}

/// ABI 4: controller type (0 unknown, 1 Xbox, 2 PlayStation, 3 Nintendo), its buttons and
/// what Mystic delivers for it. Touchpad contacts are not sent, so that bit is refused.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_controller_announce(
    handle: *mut MysticSession, slot: u8, mask: u16, kind: u8, supported_buttons: u32, capabilities: u16, epoch: u64,
) -> i32 {
    use nightjar_core::input::packets::capability;
    if slot >= MAX_CONTROLLERS || kind > 3 || supported_buttons & !controller_buttons::KNOWN != 0
        || capabilities & !delivered_capabilities() != 0 { return MYSTIC_ERR_INVALID_ARGUMENT; }
    if let Some(handle) = handle.as_ref() {
        handle.feedback.lock().unwrap_or_else(|e| e.into_inner()).clear_slot(slot, epoch);
    }
    with_input(handle, |q| q.send_controller_arrival(slot, mask, kind, supported_buttons, capabilities | capability::ANALOG_TRIGGERS))
}

/// Accelerometer (kind 1, m/s² with gravity) or gyroscope (kind 2, degrees per second).
/// MYSTIC_ERR_UNIMPLEMENTED when the host takes no motion; the stream carries on.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_controller_motion(handle: *mut MysticSession, slot: u8, kind: u8, x: f32, y: f32, z: f32) -> i32 {
    use nightjar_core::input::packets::motion_type;
    if slot >= MAX_CONTROLLERS || !matches!(kind, motion_type::ACCEL | motion_type::GYRO)
        || ![x, y, z].iter().all(|v| v.is_finite()) { return MYSTIC_ERR_INVALID_ARGUMENT; }
    with_optional_input(handle, |q| q.send_controller_motion(slot, kind, x, y, z))
}

/// Battery state (0 unknown, 1 none, 2 discharging, 3 charging, 5 full) and percent
/// (0–100, 255 unknown). MYSTIC_ERR_UNIMPLEMENTED when the host takes no battery reports.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_controller_battery(handle: *mut MysticSession, slot: u8, state: u8, percent: u8) -> i32 {
    if slot >= MAX_CONTROLLERS || !matches!(state, 0 | 1 | 2 | 3 | 5) || (percent > 100 && percent != 0xFF) {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    with_optional_input(handle, |q| q.send_controller_battery(slot, state, percent))
}

/// The network toward the host changed (`metered`: it bills by data). Returns 0 when the
/// stream roamed onto it, 1 when its connection carries on, 2 when it cannot continue there
/// (another address, not roamed), or a negative error. Serialized with start/stop.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_network_changed(handle: *const MysticSession, metered: bool) -> i32 {
    use nightjar_core::session::{NetworkChange, NetworkHint};
    let Some(session) = handle.as_ref().and_then(|h| h.session.as_ref()) else { return MYSTIC_ERR_NOT_STARTED };
    match session.network_changed(NetworkHint { metered }) {
        NetworkChange::Roamed => 0,
        NetworkChange::CarriesOn => 1,
        NetworkChange::CannotContinue => 2,
    }
}

/// Live handle, serialized with start/stop. Only encrypted negotiated streams are exposed.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_microphone_available(handle:*const MysticSession) -> bool {
    handle.as_ref().and_then(|h|h.session.as_ref()).is_some_and(|s|s.microphone_available())
}
#[no_mangle]
pub unsafe extern "C" fn mystic_session_send_microphone(handle:*const MysticSession,data:*const u8,length:usize) -> i32 {
    if data.is_null() || length==0 || length>1275 { return MYSTIC_ERR_INVALID_ARGUMENT; }
    let Some(s)=handle.as_ref().and_then(|h|h.session.as_ref()) else { return MYSTIC_ERR_NOT_STARTED; };
    if !s.microphone_available() { return MYSTIC_ERR_UNIMPLEMENTED; }
    match s.send_microphone(std::slice::from_raw_parts(data,length)) { Ok(())=>MYSTIC_OK,Err(_)=>MYSTIC_ERR_INPUT_FAILED }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_adapter_preserves_negotiated_opus_configuration() {
        unsafe extern "C" fn capture(user: *mut c_void, setup: *const MysticAudioSetup) -> i32 {
            *(user as *mut MysticAudioSetup) = *setup;
            0
        }
        let mut captured = MysticAudioSetup::default();
        let callbacks = MysticCallbacks {
            user: (&mut captured as *mut MysticAudioSetup).cast(),
            audio_init: Some(capture),
            ..Default::default()
        };
        let mut adapter = AudioAdapter { callbacks };
        let setup = AudioSetup {
            configuration: AudioConfiguration { channel_count: 6, channel_mask: 0x3f },
            opus: nightjar_core::rtsp::OpusConfig { sample_rate: 48000, channel_count: 6,
                streams: 4, coupled_streams: 2, mapping: [0,4,1,5,2,3,6,7,8,9,10,11] },
            codec: rubylight_protocol::audio_ext::CODEC_OPUS,
            packet_duration_ms: 10, samples_per_frame: 480,
        };
        assert_eq!(adapter.init(&setup), Ok(()));
        assert_eq!(captured.channel_count, 6); assert_eq!(captured.channel_mask, 0x3f);
        assert_eq!(captured.packet_duration_ms, 10); assert_eq!(captured.samples_per_frame, 480);
        assert_eq!(captured.sample_rate, 48000); assert_eq!(captured.streams, 4);
        assert_eq!(captured.coupled_streams, 2); assert_eq!(captured.mapping, [0,4,1,5,2,3,6,7]);

        let mut surround = setup;
        surround.configuration = AudioConfiguration::SURROUND_71;
        surround.opus.channel_count = 8;
        assert_eq!(adapter.init(&surround), Ok(()));
        assert_eq!(captured.channel_count, 8);
        assert_eq!(captured.mapping, [0,4,1,5,2,3,6,7]);

        let mut unsupported = setup;
        unsupported.configuration = AudioConfiguration::SURROUND_714;
        unsupported.opus.channel_count = 12;
        assert_eq!(adapter.init(&unsupported), Err(MYSTIC_ERR_UNIMPLEMENTED));
        for codec in [rubylight_protocol::audio_ext::CODEC_PCM,
                      rubylight_protocol::audio_ext::CODEC_AC3,
                      rubylight_protocol::audio_ext::CODEC_EAC3] {
            unsupported = setup;
            unsupported.codec = codec;
            assert_eq!(adapter.init(&unsupported), Err(MYSTIC_ERR_UNIMPLEMENTED));
        }
        assert_eq!(captured.channel_count, 8, "unsupported setups must not reach Swift");
    }

    #[test]
    fn network_settings_reach_the_engine() {
        use rubylight_protocol::fec_report::FecChoice;
        assert_eq!(fec_choice(MYSTIC_FEC_HOST), FecChoice::Host);
        assert_eq!(fec_choice(MYSTIC_FEC_AUTO), FecChoice::Auto);
        assert_eq!(fec_choice(30), FecChoice::Fixed(30));
        assert_eq!(fec_choice(-7), FecChoice::Host, "unknown values leave it to the host");
        let config = MysticStreamConfig { video_fec: 20, link_mbps: 2500, client_wireless: false, ..Default::default() }.to_engine();
        assert_eq!((config.video_fec, config.pyrowave_link_mbps), (FecChoice::Fixed(20), 2500));
        assert_eq!(MysticStreamConfig { link_mbps: -1, ..Default::default() }.to_engine().pyrowave_link_mbps, 0);
        assert_eq!(MysticStreamConfig::default().to_engine().video_fec, FecChoice::Host);
    }

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(mystic_abi_version(), 5);
    }

    #[test]
    fn session_location_and_roaming_follow_desktop_rules() {
        use nightjar_core::session::Location;
        let base = MysticStreamConfig { network_grace_ms: 30_000, ..Default::default() };
        let auto = base.session();
        assert!(matches!(auto.location, Location::Auto));
        assert_eq!(auto.network_grace, std::time::Duration::from_secs(30));
        assert!(!auto.roaming.enabled, "roaming is off unless asked for");
        assert!(matches!(MysticStreamConfig { location: MYSTIC_LOCATION_REMOTE, ..base }.session().location, Location::Remote));
        assert!(matches!(MysticStreamConfig { location: MYSTIC_LOCATION_LOCAL, ..base }.session().location, Location::Local));
        assert!(matches!(MysticStreamConfig { location: 9, ..base }.session().location, Location::Auto));
        let watched = MysticStreamConfig { client_roaming: true, network_hints: true, ..base }.session().roaming;
        assert!(watched.enabled && watched.platform_hints && !watched.metered);
        // Without hints the session cannot tell a metered network, so it roams only when that is allowed.
        assert!(!MysticStreamConfig { client_roaming: true, ..base }.session().roaming.enabled);
        let anywhere = MysticStreamConfig { client_roaming: true, roaming_metered: true, ..base }.session().roaming;
        assert!(anywhere.enabled && anywhere.metered && !anywhere.platform_hints);
        unsafe {
            assert_eq!(mystic_session_network_changed(std::ptr::null(), false), MYSTIC_ERR_NOT_STARTED);
            let handle = mystic_session_new();
            assert_eq!(mystic_session_network_changed(handle, true), MYSTIC_ERR_NOT_STARTED);
            mystic_session_free(handle);
        }
    }

    #[test]
    fn controller_entry_points_take_sixteen_slots_and_only_delivered_features() {
        use nightjar_core::input::packets::{button, capability};
        unsafe {
            let handle = mystic_session_new();
            // Valid arguments reach the session check; anything else is refused first.
            assert_eq!(mystic_session_controller(handle, 15, 0x8000, button::SPECIAL | button::PADDLE4, 0, 0, 0, 0, 0, 0), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_controller(handle, 16, 1, 0, 0, 0, 0, 0, 0, 0), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_controller(handle, 0, 1, 0x40_0000, 0, 0, 0, 0, 0, 0), MYSTIC_ERR_INVALID_ARGUMENT);
            let all = capability::RUMBLE | capability::TRIGGER_RUMBLE | capability::ACCEL | capability::GYRO
                | capability::BATTERY_STATE | capability::RGB_LED;
            assert_eq!(mystic_session_controller_announce(handle, 15, 0xFFFF, 2, controller_buttons::KNOWN, all, 1), MYSTIC_ERR_NOT_STARTED);
            for (slot, kind, buttons, caps) in [(16, 0, 0, 0), (0, 4, 0, 0), (0, 0, 0x40_0000, 0),
                (0, 0, 0, capability::TOUCHPAD), (0, 0, 0, capability::DUAL_TOUCHPAD), (0, 0, 0, capability::HAPTICS_PCM)] {
                assert_eq!(mystic_session_controller_announce(handle, slot, 1, kind, buttons, caps, 0), MYSTIC_ERR_INVALID_ARGUMENT, "{slot} {kind} {buttons:#x} {caps:#x}");
            }
            assert_eq!(mystic_session_controller_arrival_with_feedback(handle, 4, 0x10, capability::RUMBLE, 0), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_controller_motion(handle, 15, 2, 1.0, 2.0, 3.0), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_controller_motion(handle, 0, 3, 1.0, 2.0, 3.0), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_controller_motion(handle, 0, 1, f32::NAN, 0.0, 0.0), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_controller_battery(handle, 15, 5, 100), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_controller_battery(handle, 0, 2, 0xFF), MYSTIC_ERR_NOT_STARTED);
            for (state, percent) in [(4, 50), (6, 50), (2, 101)] {
                assert_eq!(mystic_session_controller_battery(handle, 0, state, percent), MYSTIC_ERR_INVALID_ARGUMENT);
            }
            mystic_session_free(handle);
        }
    }

    #[test]
    fn handle_lifecycle() {
        unsafe {
            let handle = mystic_session_new();
            assert!(!handle.is_null());
            // Stopping before starting reports NOT_STARTED rather than crashing.
            assert_eq!(mystic_session_stop(handle), MYSTIC_ERR_NOT_STARTED);
            mystic_session_free(handle);
        }
    }

    #[test]
    fn null_arguments_are_rejected() {
        unsafe {
            let mut buffer = [0 as c_char; 64];
            let code = mystic_session_start(
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                buffer.as_mut_ptr(),
                buffer.len(),
            );
            assert_eq!(code, MYSTIC_ERR_INVALID_ARGUMENT);
            let message = CStr::from_ptr(buffer.as_ptr()).to_string_lossy();
            assert!(message.contains("null session handle"), "got {message}");
        }
    }

    #[test]
    fn error_text_is_truncated_not_overflowed() {
        unsafe {
            let mut buffer = [0 as c_char; 8];
            let code = mystic_session_start(
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                buffer.as_mut_ptr(),
                buffer.len(),
            );
            assert_eq!(code, MYSTIC_ERR_INVALID_ARGUMENT);
            let message = CStr::from_ptr(buffer.as_ptr())
                .to_string_lossy()
                .into_owned();
            assert!(
                message.len() <= 7,
                "message longer than the buffer: {message}"
            );
        }
    }

    #[test]
    fn input_before_start_reports_not_started() {
        unsafe {
            let handle = mystic_session_new();
            assert_eq!(
                mystic_session_mouse_move(handle, 4, -3),
                MYSTIC_ERR_NOT_STARTED
            );
            assert_eq!(
                mystic_session_mouse_position(handle, 10, 20, 1920, 1080),
                MYSTIC_ERR_NOT_STARTED
            );
            assert_eq!(
                mystic_session_mouse_button(handle, 1, true),
                MYSTIC_ERR_NOT_STARTED
            );
            assert_eq!(
                mystic_session_keyboard(handle, 0x41, true, 0, 0),
                MYSTIC_ERR_NOT_STARTED
            );
            assert_eq!(mystic_session_scroll(handle, 1), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_horizontal_scroll(handle, 120), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(
                mystic_session_high_res_scroll(handle, 120),
                MYSTIC_ERR_NOT_STARTED
            );
            assert_eq!(mystic_session_request_idr(handle), MYSTIC_ERR_NOT_STARTED);

            // A null handle is rejected rather than dereferenced.
            assert_eq!(
                mystic_session_mouse_button(std::ptr::null_mut(), 1, true),
                MYSTIC_ERR_INVALID_ARGUMENT
            );
            assert_eq!(
                mystic_session_request_idr(std::ptr::null_mut()),
                MYSTIC_ERR_INVALID_ARGUMENT
            );

            mystic_session_free(handle);
        }
    }

    #[test]
    fn start_fails_cleanly_without_a_host() {
        unsafe {
            let handle = mystic_session_new();
            let c_address = CString::new("127.0.0.1").unwrap();
            let c_version = CString::new("7.1.431.-1").unwrap();
            let config = MysticStreamConfig::default();
            let callbacks = MysticCallbacks::default();
            let mut buffer = [0 as c_char; 256];

            let code = mystic_session_start(
                handle,
                c_address.as_ptr(),
                c_version.as_ptr(),
                std::ptr::null(),
                0,
                &config,
                &callbacks,
                buffer.as_mut_ptr(),
                buffer.len(),
            );

            // Nothing is listening on that port, so the handshake must fail rather than
            // hang or abort.
            assert_eq!(code, MYSTIC_ERR_START_FAILED);
            let message = CStr::from_ptr(buffer.as_ptr())
                .to_string_lossy()
                .into_owned();
            assert!(!message.is_empty(), "no error text was written");
            // A failed start leaves the handle reusable.
            assert_eq!(mystic_session_stop(handle), MYSTIC_ERR_NOT_STARTED);
            mystic_session_free(handle);
        }
    }
}
