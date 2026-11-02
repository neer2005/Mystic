//! Phase lock: tells a Rubylight host how long frames wait for this Mac's next display latch, so
//! it can time them to land just before it. Nightjar's desktop `stream::phase`; the app supplies the
//! latch and period, which the Mac reports through Metal's present times.
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED, MYSTIC_ERR_UNIMPLEMENTED};
use nightjar_core::control::ClientMessage;
use rubylight_protocol::phase_lock::{Report, SlackWindow, REPORT_MESSAGE_TYPE};

#[derive(Default)]
pub(crate) struct PhaseReports {
    announced: bool,
    window: SlackWindow,
    last_report: u64,
    last_frame: u64,
}

impl PhaseReports {
    pub fn announce(&mut self, messages: &[u16]) {
        *self = Self { announced: messages.contains(&REPORT_MESSAGE_TYPE), ..Self::default() };
    }
    fn reset(&mut self) {
        *self = Self { announced: self.announced, ..Self::default() };
    }
    /// Nightjar's `Phase::sample`: a report every half second, once ten frames say something.
    fn sample(&mut self, ready_us: u64, now_us: u64, latch_us: i64, period_ns: i64) -> Option<Report> {
        if !(2_000_000..=41_700_000).contains(&period_ns) || now_us.saturating_sub(ready_us) > 250_000 {
            self.reset();
            return None;
        }
        if self.last_frame == 0 || now_us.saturating_sub(self.last_frame) > 250_000 {
            self.reset();
            self.last_report = now_us;
        }
        self.last_frame = now_us;
        self.window.push((latch_us - ready_us as i64) * 1000, period_ns);
        if now_us.saturating_sub(self.last_report) < 500_000 {
            return None;
        }
        self.last_report = now_us;
        self.window.report(10)
    }
}

/// One frame about to be shown, all on one microsecond clock: 1 when a report went to the host, with
/// its lead in `lead_us`; 0 when none is due; MYSTIC_ERR_UNIMPLEMENTED when the host takes none.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_phase_sample(handle: *const MysticSession, ready_us: u64, now_us: u64, latch_us: i64,
                                                     period_ns: i64, lead_us: *mut i32) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let Some(session) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    let mut reports = handle.phase.lock().unwrap_or_else(|e| e.into_inner());
    if !reports.announced {
        return MYSTIC_ERR_UNIMPLEMENTED;
    }
    let Some(report) = reports.sample(ready_us, now_us, latch_us, period_ns) else { return 0 };
    if session.send(ClientMessage::PhaseLockReport(report)).is_err() {
        return MYSTIC_ERR_UNIMPLEMENTED;
    }
    if !lead_us.is_null() {
        *lead_us = report.lead_ns / 1000;
    }
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_every_half_second_with_the_time_to_the_next_latch() {
        let mut reports = PhaseReports::default();
        reports.announce(&[REPORT_MESSAGE_TYPE]);
        assert!(reports.announced);
        let period = 8_333_333;
        let mut report = None;
        for frame in 0..80u64 {
            let ready = 1_000_000 + frame * 8_333;
            // Ready 6 ms after a latch, so 2.3 ms before the next.
            if let Some(found) = reports.sample(ready, ready + 100, ready as i64 - 6_000, period) { report = Some(found); }
        }
        let report = report.expect("a report in 660 ms");
        assert!((report.lead_ns - 2_333_333).abs() < 10_000, "{}", report.lead_ns);
        assert_eq!(report.period_ns, period as u32);
    }

    #[test]
    fn stale_frames_and_implausible_periods_start_again() {
        let mut reports = PhaseReports::default();
        reports.announce(&[REPORT_MESSAGE_TYPE]);
        assert!(reports.sample(1_000, 2_000, 0, 1_000).is_none());
        assert!(reports.sample(1_000, 400_000, 0, 8_333_333).is_none());
        assert!(reports.announced, "a reset keeps what the host takes");
        reports.announce(&[]);
        assert!(!reports.announced);
    }
}
