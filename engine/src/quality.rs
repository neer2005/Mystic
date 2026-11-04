//! Automatic quality, as Nightjar's desktop `stream/quality.rs`: nightjar-policy's bounded
//! resolution/frame-rate ladder, asked of a host that takes the Reconfigure message. Each
//! request must be confirmed by a decoded picture of that size within five seconds, and
//! automatic bitrate gets the first answer to network pressure.
use crate::host::envelope;
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED, MYSTIC_ERR_UNIMPLEMENTED};
use nightjar_core::control::ClientMessage;
use nightjar_policy::quality::{AdaptiveQualityController, Bounds, Mode, QualityError, Target};
use nightjar_policy::stats::Stats;
use rubylight_protocol::control::Reconfigure;
use serde_json::{json, Value};
use std::ffi::c_char;

/// How long the host has to show a requested size.
pub(crate) const CONFIRM_MS: u64 = 5_000;

/// The ladder counts whole frames per second; a fractional ceiling such as 59.94 is its rung at 60.
fn hz(fps_millihz: u32) -> u32 { fps_millihz.div_ceil(1000) }

fn target(width: u32, height: u32, fps_millihz: u32) -> Option<Reconfigure> {
    let request = Reconfigure { width: width.try_into().ok()?, height: height.try_into().ok()?, fps_millihz };
    Reconfigure::decode(&request.encode())
}

fn mode(value: u8) -> Option<Mode> {
    match value {
        1 => Some(Mode::Motion),
        2 => Some(Mode::Detail),
        3 => Some(Mode::Battery),
        _ => None,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Step {
    Hold,
    Request(Reconfigure),
    Confirmed(Reconfigure),
    Stop(&'static str),
}

pub(crate) struct Quality {
    policy: AdaptiveQualityController,
    /// The exact request at the top of the ladder.
    ceiling: Reconfigure,
    pending: Option<(Reconfigure, u64)>,
}

impl Quality {
    /// As Nightjar, floors below the protocol's 256 lines are raised to it.
    pub fn new(mode: Mode, ceiling: Reconfigure, min_edge: u32, min_fps: u32, now: u64) -> Result<Self, QualityError> {
        let bounds = Bounds { min_short_edge: min_edge.max(256), min_fps, align_width: 2, align_height: 2 };
        let policy = AdaptiveQualityController::new(mode, u32::from(ceiling.width), u32::from(ceiling.height),
            hz(ceiling.fps_millihz), bounds, now)?;
        Ok(Self { policy, ceiling, pending: None })
    }
    fn request(&self, rung: Target) -> Option<Reconfigure> {
        let fps_millihz = if rung.fps == hz(self.ceiling.fps_millihz) { self.ceiling.fps_millihz } else { rung.fps * 1000 };
        target(rung.width, rung.height, fps_millihz)
    }
    fn rung(request: Reconfigure) -> Target {
        Target { width: u32::from(request.width), height: u32::from(request.height), fps: hz(request.fps_millihz) }
    }
    /// One second of the stream: `tick` is the doctor's sample (None when there was none),
    /// `decoded` the size of the latest decoded picture, `suspended` while the stream is not in
    /// front, when the ladder must not move.
    pub fn step(&mut self, tick: Option<&Stats>, has_room: bool, suspended: bool, decoded: (u32, u32), now: u64) -> Step {
        if let Some((request, at)) = self.pending {
            if decoded == (u32::from(request.width), u32::from(request.height)) {
                self.pending = None;
                return Step::Confirmed(request);
            }
            if now.saturating_sub(at) >= CONFIRM_MS {
                return Step::Stop("The host did not show the requested size within 5 seconds. Automatic quality stopped.");
            }
            self.policy.suspend();
            return Step::Hold;
        }
        if suspended {
            self.policy.suspend();
            return Step::Hold;
        }
        let Some(tick) = tick else { return Step::Hold };
        let Some(next) = self.policy.sample_timed(tick, has_room, None) else { return Step::Hold };
        let Some(request) = self.request(next) else {
            return Step::Stop("This stream cannot use the size or frame rate automatic quality chose. Automatic quality stopped.");
        };
        if self.policy.applied(Self::rung(request), now).is_err() {
            return Step::Stop("Automatic quality lost its place on the ladder and stopped.");
        }
        self.pending = Some((request, now));
        Step::Request(request)
    }
}

/// Starts the ladder at the stream's negotiated size and rate. `mode`: 1 smooth motion,
/// 2 sharp detail, 3 battery life. MYSTIC_ERR_UNIMPLEMENTED when the host takes no Reconfigure.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_quality_begin(p: *mut MysticSession, mode: u8, min_short_edge: u32, min_fps: u32, now_ms: u64) -> i32 {
    let Some(p) = p.as_mut() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    if p.session.is_none() { return MYSTIC_ERR_NOT_STARTED; }
    let Some(mode) = self::mode(mode) else { return MYSTIC_ERR_INVALID_ARGUMENT };
    if !p.reconfigure.load(std::sync::atomic::Ordering::Acquire) { return MYSTIC_ERR_UNIMPLEMENTED; }
    let network = p.network.lock().unwrap_or_else(|e| e.into_inner());
    let Some(ceiling) = target(network.width, network.height, network.fps.saturating_mul(1000)) else { return MYSTIC_ERR_INVALID_ARGUMENT };
    drop(network);
    match Quality::new(mode, ceiling, min_short_edge, min_fps, now_ms) {
        Ok(quality) => { p.quality = Some(quality); 0 }
        Err(_) => MYSTIC_ERR_INVALID_ARGUMENT,
    }
}

/// One tick, after the health tick of the same second. Returns an envelope whose value names
/// the state ("off", "hold", "requested", "confirmed" or "stopped") with the size and rate it
/// concerns, and the reason when it stopped.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_quality_tick(p: *mut MysticSession, decoded_width: u32, decoded_height: u32,
    suspended: bool, now_ms: u64) -> *mut c_char {
    envelope((|| {
        let p = p.as_mut().ok_or("No stream is running.")?;
        let session = p.session.as_ref().ok_or("No stream is running.")?;
        let tick = p.last_tick.take();
        let Some(quality) = p.quality.as_mut() else { return Ok(json!({"state":"off"})) };
        let has_room = p.bitrate.as_ref().is_some_and(|b| b.has_room())
            || p.rates.lock().unwrap_or_else(|e| e.into_inner()).hint_has_room();
        let describe = |state: &str, r: Reconfigure| json!({"state":state,"width":r.width,"height":r.height,"fpsMilliHz":r.fps_millihz});
        let value: Value = match quality.step(tick.as_ref(), has_room, suspended, (decoded_width, decoded_height), now_ms) {
            Step::Hold => json!({"state":"hold"}),
            Step::Confirmed(r) => describe("confirmed", r),
            Step::Request(r) => {
                if session.send(ClientMessage::Reconfigure(r)).is_err() {
                    p.quality = None;
                    return Ok(json!({"state":"stopped","reason":"The stream did not accept the size change. Automatic quality stopped."}));
                }
                let (width, height, fps) = (u32::from(r.width), u32::from(r.height), hz(r.fps_millihz));
                {
                    let mut network = p.network.lock().unwrap_or_else(|e| e.into_inner());
                    network.width = width;
                    network.height = height;
                    network.fps = fps;
                }
                if let Some(bitrate) = p.bitrate.as_mut() { bitrate.set_mode(width, height, fps); }
                describe("requested", r)
            }
            Step::Stop(reason) => {
                p.quality = None;
                json!({"state":"stopped","reason":reason})
            }
        };
        Ok(value)
    })())
}

#[no_mangle]
pub unsafe extern "C" fn mystic_session_quality_end(p: *mut MysticSession) {
    if let Some(p) = p.as_mut() { p.quality = None; }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tick(now_ms: u64, decode_ms: f32) -> Stats {
        Stats { now_ms, recent_video: true, fps: 60, loss_percent: Some(0.0), decode_ms: Some(decode_ms),
            jitter_ms: Some(1.0), queue_ms: Some(1.0), ..Default::default() }
    }
    fn ceiling() -> Reconfigure { target(1920, 1080, 60_000).unwrap() }

    /// Seconds of a decoder too slow for the stream, until the ladder asks for a step.
    fn pressure(quality: &mut Quality, from_s: u64, decoded: (u32, u32)) -> (u64, Step) {
        for second in from_s..from_s + 120 {
            let step = quality.step(Some(&tick(second * 1000, 200.0)), false, false, decoded, second * 1000);
            if step != Step::Hold { return (second, step); }
        }
        panic!("no step under sustained pressure");
    }

    #[test]
    fn a_slow_decoder_steps_down_and_the_host_must_show_the_size() {
        let mut quality = Quality::new(Mode::Motion, ceiling(), 720, 30, 0).unwrap();
        let (at, step) = pressure(&mut quality, 1, (1920, 1080));
        let Step::Request(request) = step else { panic!("{step:?}") };
        assert!(u32::from(request.height) < 1080 || request.fps_millihz < 60_000, "a lower rung: {request:?}");
        assert!(u32::from(request.height) >= 720 && request.fps_millihz >= 30_000, "within the floors: {request:?}");
        // Until the new size is decoded the ladder holds, whatever the samples say.
        assert_eq!(quality.step(Some(&tick(at * 1000 + 1000, 200.0)), false, false, (1920, 1080), at * 1000 + 1000), Step::Hold);
        let shown = (u32::from(request.width), u32::from(request.height));
        assert_eq!(quality.step(None, false, false, shown, at * 1000 + 2000), Step::Confirmed(request));
    }

    #[test]
    fn an_unconfirmed_size_stops_automatic_quality_after_five_seconds() {
        // Sharp detail gives up frame rate first: the size stays, so it is confirmed at once.
        let mut detail = Quality::new(Mode::Detail, ceiling(), 720, 30, 0).unwrap();
        let (at, step) = pressure(&mut detail, 1, (1920, 1080));
        let Step::Request(request) = step else { panic!("{step:?}") };
        assert_eq!((request.width, request.height), (1920, 1080));
        assert!(request.fps_millihz < 60_000);
        assert_eq!(detail.step(None, false, false, (1920, 1080), at * 1000 + 1000), Step::Confirmed(request));
        let mut quality = Quality::new(Mode::Motion, ceiling(), 720, 30, 0).unwrap();
        let (at, step) = pressure(&mut quality, 1, (1920, 1080));
        assert!(matches!(step, Step::Request(r) if r.height < 1080));
        let now = at * 1000 + CONFIRM_MS - 1;
        assert_eq!(quality.step(None, false, false, (1920, 1080), now), Step::Hold);
        assert!(matches!(quality.step(None, false, false, (1920, 1080), now + 1), Step::Stop(_)));
    }

    #[test]
    fn a_suspended_stream_and_room_for_bitrate_hold_the_ladder() {
        let mut quality = Quality::new(Mode::Motion, ceiling(), 720, 30, 0).unwrap();
        for second in 1..200 {
            let now = second * 1000;
            assert_eq!(quality.step(Some(&tick(now, 200.0)), false, true, (1920, 1080), now), Step::Hold, "suspended at {second}s");
        }
        // Network pressure that automatic bitrate can still answer is left to it.
        let lossy = |now_ms| Stats { loss_percent: Some(20.0), decode_ms: Some(2.0), ..tick(now_ms, 2.0) };
        for second in 200..400 {
            let now = second * 1000;
            assert_eq!(quality.step(Some(&lossy(now)), true, false, (1920, 1080), now), Step::Hold, "bitrate has room at {second}s");
        }
    }

    #[test]
    fn modes_and_the_c_entry_points_refuse_what_they_cannot_do() {
        assert_eq!(mode(0), None);
        assert_eq!(mode(4), None);
        assert_eq!(mode(3), Some(Mode::Battery));
        assert_eq!(hz(59_940), 60);
        unsafe {
            assert_eq!(mystic_session_quality_begin(std::ptr::null_mut(), 1, 720, 30, 0), MYSTIC_ERR_INVALID_ARGUMENT);
            let handle = crate::mystic_session_new();
            assert_eq!(mystic_session_quality_begin(handle, 1, 720, 30, 0), MYSTIC_ERR_NOT_STARTED);
            mystic_session_quality_end(handle);
            crate::mystic_session_free(handle);
        }
    }
}
