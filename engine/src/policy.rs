//! Additive ABI over Nightjar's shared policies. All policy calls are serialized by the owner.
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT};
use nightjar_core::{control::ConnectionStatus, session::SessionStats};
use nightjar_policy::{
    bitrate::{AdaptiveBitrateController, Codec},
    recovery::{self, Backoff},
    stats::Stats,
};

#[derive(Default)]
pub(crate) struct NetworkTiming {
    pub format: u32,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    last: Option<(u32, u64)>,
    jitter: Option<f32>,
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
    pub fn frame(&mut self, rtp: u32, received: u64) {
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
        n.frame(u32::MAX - 1499, 1000);
        n.frame(0, 17667);
        assert!(n.jitter.unwrap() < 0.01);
        n.frame(900_000, 18000);
        assert!(n.jitter.is_none());
    }
}
