//! Clock sync (0x5537): the offset from the host's video clock to this Mac's, so a frame's time on the
//! PC can be compared with when it arrived and when it was shown. Nightjar's `ClockOffset`, probed by the app.
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED, MYSTIC_ERR_UNIMPLEMENTED};
use nightjar_core::control::ControlEvent;
use nightjar_core::session;
use rubylight_protocol::control::CLOCK_SYNC_MESSAGE_TYPE;
use rubylight_protocol::present_clock::ClockOffset;

#[derive(Default)]
pub(crate) struct ClockSync {
    announced: bool,
    offset: ClockOffset,
}

impl ClockSync {
    pub fn announce(&mut self, messages: &[u16]) {
        self.announced = messages.contains(&CLOCK_SYNC_MESSAGE_TYPE);
        self.offset.clear();
    }
    /// The offset and round trip at `at_us`, when replies have come.
    pub fn offset(&self, at_us: i64) -> Option<(i64, i64)> {
        self.offset.offset_at(at_us).zip(self.offset.rtt_us())
    }
    pub fn receive(&mut self, event: ControlEvent) {
        if let ControlEvent::ClockSync { reply, received } = event {
            let receive_us = session::now_us().saturating_sub(received.elapsed().as_micros() as u64);
            self.offset.add(&reply, receive_us);
        }
    }
}

/// The clock frames' `receive_time_us` and the offset are on.
#[no_mangle]
pub extern "C" fn mystic_clock_now_us() -> u64 {
    session::now_us()
}

/// Sends a probe, about four a second as Nightjar. 1 with the offset (`client = host + offset`) and the
/// round trip it came from; 0 while no reply has come; MYSTIC_ERR_UNIMPLEMENTED when the host takes none.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_clock_sync(handle: *const MysticSession, offset_us: *mut i64, rtt_us: *mut i64) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let Some(active) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    let clock = handle.clock.lock().unwrap_or_else(|e| e.into_inner());
    if !clock.announced {
        return MYSTIC_ERR_UNIMPLEMENTED;
    }
    let now = session::now_us();
    let known = clock.offset.offset_at(now as i64).zip(clock.offset.rtt_us());
    drop(clock);
    if active.send_clock_sync_probe(now).is_err() {
        return MYSTIC_ERR_UNIMPLEMENTED;
    }
    let Some((offset, rtt)) = known else { return 0 };
    if !offset_us.is_null() { *offset_us = offset; }
    if !rtt_us.is_null() { *rtt_us = rtt; }
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_host_that_lists_the_message_is_probed() {
        let mut clock = ClockSync::default();
        clock.announce(&[]);
        assert!(!clock.announced);
        clock.announce(&[CLOCK_SYNC_MESSAGE_TYPE]);
        assert!(clock.announced);
        assert_eq!(clock.offset.rtt_us(), None);
    }
}
