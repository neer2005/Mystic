//! Additive ABI over Nightjar's shared policies. All policy calls are serialized by the owner.
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT};
use nightjar_core::{control::ConnectionStatus, session::SessionStats};
use nightjar_policy::{
    bitrate::{AdaptiveBitrateController, Codec},
    recovery::{self, Backoff},
    stats::{LateFrames, Stats},
};

#[derive(Default)]
pub(crate) struct NetworkTiming {
    pub format: u32,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    last: Option<(u32, u64)>,
    pub(crate) jitter: Option<f32>,
    /// Frames late against the host's clock, for the stream doctor's bursts.
    pub(crate) late: LateFrames,
    /// Frames received since the doctor's last tick.
    pub(crate) received: u64,
    /// Their video payload in bytes, for the overlay's Mbit/s.
    pub(crate) received_bytes: u64,
}
impl NetworkTiming {
    pub fn setup(&mut self, format: u32, width: u32, height: u32, fps: u32) {
        *self = Self {
            format,
            width,
            height,
            fps,
            ..Self::default()
        };
    }
    pub fn frame(&mut self, rtp: u32, received: u64, processing_us: u32) {
        self.late.push(rtp, processing_us, received, self.fps);
        self.received += 1;
        if let Some((last_rtp, last_us)) = self.last {
            let ticks = rtp.wrapping_sub(last_rtp) as i32;
            if ticks > 0 && ticks <= 90_000 && received >= last_us {
                let delta = ((received - last_us) as f32 / 1000.0 - ticks as f32 / 90.0).abs();
                self.jitter = Some(self.jitter.map_or(delta, |j| j + (delta - j) / 16.0));
            } else {
                self.jitter = None;
            }
        }
        self.last = Some((rtp, received));
    }
}

pub struct MysticRecovery(Backoff);
#[no_mangle]
pub extern "C" fn mystic_recovery_new() -> *mut MysticRecovery {
    Box::into_raw(Box::new(MysticRecovery(Backoff::default())))
}
#[no_mangle]
pub unsafe extern "C" fn mystic_recovery_free(p: *mut MysticRecovery) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}
#[no_mangle]
pub extern "C" fn mystic_recovers_termination(code: i32, video_started: bool) -> bool {
    recovery::recovers_termination(code, video_started)
}
#[no_mangle]
pub extern "C" fn mystic_recovers_startup(stage: i32, code: i32) -> bool {
    // Explicit allowlist: decode/audio failures and host status codes remain manual.
    matches!(stage, 2 | 4 | 5 | 8 | 11) && recovery::transport_termination(code)
}
#[no_mangle]
pub unsafe extern "C" fn mystic_recovery_next(
    p: *mut MysticRecovery,
    now_ms: u64,
    connected_ms: u64,
) -> i64 {
    let Some(p) = p.as_mut() else {
        return -1;
    };
    p.0.reset_after(connected_ms);
    p.0.begin(now_ms);
    p.0.next_delay(now_ms).map_or(-1, |delay| delay as i64)
}
/// The next attempt starts without its delay (the network came back); it still spends one.
#[no_mangle]
pub unsafe extern "C" fn mystic_recovery_retry_now(p: *mut MysticRecovery) {
    if let Some(p) = p.as_mut() { p.0.retry_now(); }
}
/// Nightjar's rule for a network back after the stream's was lost: reconnect now only when the
/// connection cannot carry on over it, and only when nothing else decides.
#[no_mangle]
pub extern "C" fn mystic_reconnects_at_once(cannot_continue: bool, metered: bool, mobile_allowed: bool,
    auto_reconnect: bool, network_grace_ms: u32) -> bool {
    recovery::reconnects_at_once(cannot_continue, metered, mobile_allowed, auto_reconnect, network_grace_ms)
}
#[no_mangle]
pub unsafe extern "C" fn mystic_recovery_remaining(p: *const MysticRecovery, now_ms: u64) -> u64 {
    p.as_ref().map_or(0, |p| p.0.remaining(now_ms))
}

pub(crate) struct Bitrate {
    controller: AdaptiveBitrateController,
    completed: u64,
    drops: u64,
    pending: Option<u32>,
}
impl Bitrate {
    fn new(ceiling: u32, current: u32, n: &NetworkTiming, now: u64) -> Self {
        let codec = if n.format & 0xf000 != 0 {
            Some(Codec::Av1)
        } else if n.format & 0xf00 != 0 {
            Some(Codec::Hevc)
        } else if n.format & 0xf != 0 {
            Some(Codec::H264)
        } else {
            None
        };
        Self {
            controller: AdaptiveBitrateController::with_stream(
                ceiling, current, n.fps, now, n.width, n.height, codec,
            ),
            completed: 0,
            drops: 0,
            pending: None,
        }
    }
    fn sample(&mut self, stats: &SessionStats, n: &NetworkTiming, decode_ms: f32, now: u64) -> u32 {
        let completed = stats.video.frames_completed.saturating_sub(self.completed);
        let drops = stats.video.frame_drops.saturating_sub(self.drops);
        self.completed = stats.video.frames_completed;
        self.drops = stats.video.frame_drops;
        if self.pending.is_some() {
            self.controller.suspend();
            return 0;
        }
        let tick = Stats {
            now_ms: now,
            recent_video: completed > 0 && decode_ms.is_finite() && decode_ms >= 0.0,
            poor_connection: stats.connection_status == Some(ConnectionStatus::Poor),
            fps: n.fps,
            loss_percent: (completed + drops > 0)
                .then(|| drops as f32 * 100.0 / (completed + drops) as f32),
            decode_ms: (decode_ms.is_finite() && decode_ms >= 0.0).then_some(decode_ms),
            jitter_ms: n.jitter,
            ..Stats::default()
        };
        self.pending = self.controller.sample(&tick);
        self.pending.unwrap_or(0)
    }
}
impl Bitrate {
    /// Automatic bitrate can still answer network pressure, so automatic quality waits.
    pub(crate) fn has_room(&self) -> bool {
        self.pending.is_some() || self.controller.has_room_before_quality_reduction()
    }
    /// Automatic quality changed the stream's size or rate.
    pub(crate) fn set_mode(&mut self, width: u32, height: u32, fps: u32) {
        self.controller.set_frame_rate(fps);
        self.controller.set_stream_size(width, height);
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_session_bitrate_begin(
    p: *mut MysticSession,
    ceiling: u32,
    current: u32,
    now: u64,
) -> i32 {
    let Some(p) = p.as_mut() else {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    if p.session.is_none() || !(1..=150_000).contains(&ceiling) || current == 0 || current > ceiling
    {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    let n = p.network.lock().unwrap_or_else(|e| e.into_inner());
    let mut rate = Bitrate::new(ceiling, current, &n, now);
    // `current` is the host's answer to the initial request for `ceiling`.
    // Preserve a lower host cap before the first sample can probe upward.
    rate.controller.applied(ceiling, current, now);
    let stats = p.session.as_ref().unwrap().stats();
    rate.completed = stats.video.frames_completed;
    rate.drops = stats.video.frame_drops;
    p.bitrate = Some(rate);
    0
}
#[no_mangle]
pub unsafe extern "C" fn mystic_session_bitrate_sample(
    p: *mut MysticSession,
    decode_ms: f32,
    now: u64,
) -> u32 {
    let Some(p) = p.as_mut() else {
        return 0;
    };
    let (Some(session), Some(rate)) = (&p.session, &mut p.bitrate) else {
        return 0;
    };
    let n = p.network.lock().unwrap_or_else(|e| e.into_inner());
    rate.sample(&session.stats(), &n, decode_ms, now)
}
#[no_mangle]
pub unsafe extern "C" fn mystic_session_bitrate_applied(
    p: *mut MysticSession,
    requested: u32,
    applied: u32,
    now: u64,
) {
    let Some(p) = p.as_mut() else {
        return;
    };
    let Some(rate) = p.bitrate.as_mut() else {
        return;
    };
    if rate.pending == Some(requested) && applied > 0 && applied <= 2_000_000 {
        rate.controller.applied(requested, applied, now);
        rate.pending = None;
        if let Some(session) = &p.session {
            let stats = session.stats();
            rate.completed = stats.video.frames_completed;
            rate.drops = stats.video.frame_drops;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_returning_network_retries_at_once_and_still_spends_an_attempt() {
        unsafe {
            let p = mystic_recovery_new();
            assert_eq!(mystic_recovery_next(p, 0, 0), 1000);
            mystic_recovery_retry_now(p);
            assert_eq!(mystic_recovery_next(p, 1000, 0), 0);
            assert_eq!(mystic_recovery_next(p, 1000, 0), 4000, "the third attempt keeps its delay");
            mystic_recovery_retry_now(std::ptr::null_mut());
            mystic_recovery_free(p);
        }
        assert!(mystic_reconnects_at_once(true, false, false, true, 0));
        assert!(!mystic_reconnects_at_once(false, false, false, true, 0), "it carries on or roamed");
        assert!(!mystic_reconnects_at_once(true, true, false, true, 0), "metered without mobile data");
        assert!(mystic_reconnects_at_once(true, true, true, true, 10_000));
        assert!(!mystic_reconnects_at_once(true, false, false, false, 0), "automatic reconnect off");
        assert!(!mystic_reconnects_at_once(true, false, false, true, 30_000), "a drop tolerance holds it");
    }
    #[test]
    fn recovery_is_bounded_and_never_retries_before_video_or_after_clean_exit() {
        unsafe {
            let p = mystic_recovery_new();
            for (now, delay) in [
                (0, 1000),
                (1000, 2000),
                (3000, 4000),
                (7000, 8000),
                (15000, 12000),
            ] {
                assert_eq!(mystic_recovery_next(p, now, 0), delay);
            }
            assert_eq!(mystic_recovery_next(p, 27000, 0), -1);
            assert_eq!(mystic_recovery_next(p, 60000, 30000), 1000);
            mystic_recovery_free(p);
        }
        assert!(mystic_recovers_termination(-100, true));
        assert!(!mystic_recovers_termination(-100, false));
        for code in [0, -103, -104, 401] {
            assert!(!mystic_recovers_termination(code, true));
        }
        assert!(mystic_recovers_startup(4, 60));
        assert!(!mystic_recovers_startup(9, 60));
        assert!(!mystic_recovers_startup(4, 401));
    }
    #[test]
    fn loss_cuts_then_healthy_samples_recover_without_exceeding_ceiling() {
        let mut n = NetworkTiming::default();
        n.setup(0x100, 1920, 1080, 60);
        n.jitter = Some(1.0);
        let mut rate = Bitrate::new(20000, 20000, &n, 0);
        let mut stats = SessionStats::default();
        for sec in 1..=3 {
            stats.video.frames_completed += 92;
            stats.video.frame_drops += 8;
            let target = rate.sample(&stats, &n, 2.0, sec * 1000);
            if sec < 3 {
                assert_eq!(target, 0);
            } else {
                assert_eq!(target, 16000);
            }
        }
        assert_eq!(
            rate.sample(&stats, &n, 2.0, 4000),
            0,
            "one request in flight"
        );
        rate.controller.applied(16000, 15000, 4000);
        rate.pending = None;
        for sec in 5..=60 {
            stats.video.frames_completed += 60;
            assert_eq!(
                rate.sample(&stats, &n, 2.0, sec * 1000),
                0,
                "a host cap is never probed above"
            );
        }
        let mut raised = false;
        rate = Bitrate::new(15000, 10000, &n, 4000);
        for sec in 5..=100 {
            stats.video.frames_completed += 60;
            let target = rate.sample(&stats, &n, 2.0, sec * 1000);
            if target > 0 {
                assert!(target <= 15000, "host ceiling is kept");
                raised |= target > 10000;
                rate.controller.applied(target, target, sec * 1000);
                rate.pending = None;
            }
        }
        assert!(raised);
    }
    #[test]
    fn timing_handles_wrap_and_rejects_a_new_clock() {
        let mut n = NetworkTiming::default();
        n.frame(u32::MAX - 1499, 1000, 0);
        n.frame(0, 17667, 0);
        assert!(n.jitter.unwrap() < 0.01);
        n.frame(900_000, 18000, 0);
        assert!(n.jitter.is_none());
    }
}

/// Nightjar's `color::offer`: `base` with the 4:4:4 and Main10 formats wanted, that this Mac
/// decodes (`decodable`) and the PC encodes (`scm`), as JSON: `formats`, whether each was offered,
/// and the words for why not when they are worth saying.
#[no_mangle]
pub unsafe extern "C" fn mystic_color_offer(base: u32, decodable: u32, scm: u32, hdr: bool, yuv444: bool, sdr10: bool, decoder_reason: *const std::ffi::c_char) -> *mut std::ffi::c_char {
    use nightjar_core::color::{offer, Refusal, Wants};
    let reason = if decoder_reason.is_null() { "" } else { std::ffi::CStr::from_ptr(decoder_reason).to_str().unwrap_or("") };
    let result = offer(base, Wants { yuv444, sdr10, hdr, ..Default::default() }, decodable, reason, scm);
    let words = |refusal: &Refusal| match refusal {
        Refusal::Decoder(why) if why.is_empty() => "this Mac has no hardware decoder for it".to_owned(),
        Refusal::Decoder(why) => format!("this Mac's decoder: {why}"),
        Refusal::Host => "the PC does not encode it for this codec".to_owned(),
        Refusal::Yuv444 => "the PC streams 4:4:4 or 10-bit, not both, and 4:4:4 is on".to_owned(),
        _ => "another setting takes priority".to_owned(),
    };
    let said = |answer: &Result<(), Refusal>| answer.as_ref().err().filter(|r| r.worth_saying()).map(words);
    crate::host::envelope_for(Ok(serde_json::json!({"formats":result.formats,"yuv444":result.yuv444.is_ok(),"sdr10":result.sdr10.is_ok(),
        "yuv444Refusal":said(&result.yuv444),"sdr10Refusal":said(&result.sdr10)})))
}

#[cfg(test)]
mod color_tests {
    use super::*;
    use nightjar_core::sdp::*;
    fn offer(decodable: u32, scm: u32, hdr: bool, yuv444: bool, sdr10: bool) -> serde_json::Value {
        unsafe {
            let answer = mystic_color_offer(VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265, decodable, scm, hdr, yuv444, sdr10, c"no decoder".as_ptr());
            let value: serde_json::Value = serde_json::from_str(std::ffi::CStr::from_ptr(answer).to_str().unwrap()).unwrap();
            crate::host::mystic_string_free(answer);
            value["value"].clone()
        }
    }
    const PLAIN: u64 = (VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265) as u64;
    const ALL: u32 = VIDEO_FORMAT_H265_MAIN10 | VIDEO_FORMAT_H265_REXT8_444;
    const SCM: u32 = SCM_HEVC | SCM_HEVC_MAIN10 | SCM_HEVC_REXT8_444;
    #[test]
    fn nothing_extra_is_offered_unless_asked() {
        let off = offer(ALL, SCM, false, false, false);
        assert_eq!(off["formats"].as_u64().unwrap(), PLAIN);
        assert!(off["yuv444Refusal"].is_null() && off["sdr10Refusal"].is_null());
    }
    #[test]
    fn each_format_needs_the_setting_the_decoder_and_the_pc() {
        let main10 = offer(ALL, SCM, false, false, true);
        assert_eq!(main10["formats"].as_u64().unwrap(), PLAIN | u64::from(VIDEO_FORMAT_H265_MAIN10));
        let full = offer(ALL, SCM, false, true, false);
        assert_eq!(full["formats"].as_u64().unwrap(), PLAIN | u64::from(VIDEO_FORMAT_H265_REXT8_444));
        let host = offer(ALL, SCM_HEVC | SCM_HEVC_MAIN10, false, true, false);
        assert_eq!((host["yuv444"].as_bool(), host["yuv444Refusal"].as_str()), (Some(false), Some("the PC does not encode it for this codec")));
        assert_eq!(offer(0, SCM, false, true, false)["yuv444Refusal"], "this Mac's decoder: no decoder");
    }
    #[test]
    fn four_four_four_wins_over_ten_bit_and_hdr_over_both_without_a_word() {
        let both = offer(ALL, SCM, false, true, true);
        assert_eq!((both["yuv444"].as_bool(), both["sdr10"].as_bool()), (Some(true), Some(false)));
        assert!(both["sdr10Refusal"].as_str().unwrap().contains("not both"));
        let hdr = offer(ALL, SCM, true, true, true);
        assert_eq!((hdr["yuv444"].as_bool(), hdr["sdr10"].as_bool()), (Some(false), Some(false)));
        assert!(hdr["yuv444Refusal"].is_null() && hdr["sdr10Refusal"].is_null());
    }
}
