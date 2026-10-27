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

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::Arc;

use nightjar_core::input::{InputError, InputQueue};
use nightjar_core::sdp::{AudioConfiguration, StreamConfig, StreamLocation};
use nightjar_core::session::{
    AudioRenderer, AudioSetup, DecodeStatus, HostInfo, Interrupt, Listener, Session,
    SessionConfig, Stage, VideoDecoder, VideoSetup,
};
use nightjar_core::video::{Frame, FrameType};

/// Bumped whenever a struct layout or function signature changes. The Swift side refuses
/// to run against a mismatch rather than misreading memory.
pub const MYSTIC_ABI_VERSION: u32 = 1;

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
        }
    }
}

impl MysticStreamConfig {
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
            haptics_pcm: self.haptics_pcm,
            microphone: self.microphone,
            pyrowave_records_supported: self.pyrowave_records_supported,
            pyrowave_row_order: self.pyrowave_row_order,
            client_wireless: self.client_wireless,
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
    pub video_setup: Option<unsafe extern "C" fn(user: *mut c_void, setup: *const MysticVideoSetup) -> i32>,
    pub video_start: Option<unsafe extern "C" fn(user: *mut c_void)>,
    /// Return 0 for `Ok`, 1 for `NeedIdr`.
    pub video_submit: Option<unsafe extern "C" fn(user: *mut c_void, frame: *const MysticFrame) -> i32>,
    pub video_stop: Option<unsafe extern "C" fn(user: *mut c_void)>,
    pub video_cleanup: Option<unsafe extern "C" fn(user: *mut c_void)>,

    /// Return 0 to proceed, non-zero to fail the audio stage with that code.
    pub audio_init: Option<unsafe extern "C" fn(user: *mut c_void, setup: *const MysticAudioSetup) -> i32>,
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
}

impl VideoDecoder for VideoAdapter {
    fn setup(&mut self, setup: &VideoSetup) -> Result<(), i32> {
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
        let plain = MysticAudioSetup {
            channel_count: setup.configuration.channel_count,
            channel_mask: setup.configuration.channel_mask,
            packet_duration_ms: setup.packet_duration_ms,
            samples_per_frame: setup.samples_per_frame,
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
        let Some(f) = self.callbacks.audio_play else { return };
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
        write_error(error_buffer, error_capacity, "address, app_version and config are required");
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    if handle.session.is_some() {
        write_error(error_buffer, error_capacity, "session already started");
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }

    let host_info = HostInfo {
        address: CStr::from_ptr(address).to_string_lossy().into_owned(),
        app_version: CStr::from_ptr(app_version).to_string_lossy().into_owned(),
        rtsp_session_url: if rtsp_session_url.is_null() {
            None
        } else {
            Some(CStr::from_ptr(rtsp_session_url).to_string_lossy().into_owned())
        },
        server_codec_mode_support,
    };

    let callbacks = if callbacks.is_null() {
        MysticCallbacks::default()
    } else {
        *callbacks
    };

    let session_config = SessionConfig {
        stream: (*config).to_engine(),
        ..SessionConfig::default()
    };

    let video: Box<dyn VideoDecoder> = Box::new(VideoAdapter {
        callbacks,
        submitted: 0,
    });
    let audio: Box<dyn AudioRenderer> = Box::new(AudioAdapter { callbacks });
    let listener = Arc::new(ListenerAdapter { callbacks });

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
fn with_input(handle: *mut MysticSession, f: impl FnOnce(&mut InputQueue) -> Result<(), InputError>) -> i32 {
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
    with_input(handle, |q| q.send_keyboard(key_code, down, modifiers, flags))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(mystic_abi_version(), 1);
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
            let message = CStr::from_ptr(buffer.as_ptr()).to_string_lossy().into_owned();
            assert!(message.len() <= 7, "message longer than the buffer: {message}");
        }
    }

    #[test]
    fn input_before_start_reports_not_started() {
        unsafe {
            let handle = mystic_session_new();
            assert_eq!(mystic_session_mouse_move(handle, 4, -3), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(
                mystic_session_mouse_position(handle, 10, 20, 1920, 1080),
                MYSTIC_ERR_NOT_STARTED
            );
            assert_eq!(mystic_session_mouse_button(handle, 1, true), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_keyboard(handle, 0x41, true, 0, 0), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_scroll(handle, 1), MYSTIC_ERR_NOT_STARTED);
            assert_eq!(mystic_session_high_res_scroll(handle, 120), MYSTIC_ERR_NOT_STARTED);
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
            let message = CStr::from_ptr(buffer.as_ptr()).to_string_lossy().into_owned();
            assert!(!message.is_empty(), "no error text was written");
            // A failed start leaves the handle reusable.
            assert_eq!(mystic_session_stop(handle), MYSTIC_ERR_NOT_STARTED);
            mystic_session_free(handle);
        }
    }
}
