//! The Mac display's HDR luminance for the host's tone mapping. macOS reports EDR headroom
//! (peak over SDR white), not nits, so the peak is Nightjar's estimate from that ratio: the
//! rule Android uses for its HDR/SDR ratio (`DisplayLuminance::from_display`). A Rubylight
//! host gets it as the DisplayCaps message; other hosts get it in the launch query.
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED, MYSTIC_ERR_UNIMPLEMENTED};
use nightjar_core::control::ClientMessage;
use nightjar_core::http::DisplayLuminance;
use rubylight_protocol::control::{DisplayCaps, DISPLAY_CAPS_MESSAGE_TYPE};

/// The launch query's luminance, or None when the headroom gives no usable estimate.
pub(crate) fn luminance(headroom: f32) -> Option<DisplayLuminance> {
    DisplayLuminance::from_display(f32::NAN, f32::NAN, f32::NAN, headroom)
}

/// As Android's `DisplayCapsReporter`: unknown values are 0, and a black level of a nit or
/// more is unknown, since the host drops such a message.
pub(crate) fn caps(headroom: f32) -> DisplayCaps {
    let hdr = headroom.is_finite() && headroom > 1.0;
    let Some(l) = luminance(headroom).filter(|_| hdr) else {
        return DisplayCaps { hdr, ..Default::default() };
    };
    let scale = |nits: f32, per_nit: f32| (nits * per_nit + 0.5).min(u32::MAX as f32) as u32;
    DisplayCaps {
        hdr,
        max_centinits: scale(l.max_nits, 100.0),
        max_average_centinits: scale(l.max_full_frame_nits, 100.0),
        min_decimillinits: if l.min_nits >= 0.9999 { 0 } else { scale(l.min_nits, 10_000.0) },
    }
}

#[derive(Default)]
pub(crate) struct DisplayReports {
    announced: bool,
    last: Option<DisplayCaps>,
}
impl DisplayReports {
    pub fn announce(&mut self, messages: &[u16]) {
        self.announced = messages.contains(&DISPLAY_CAPS_MESSAGE_TYPE);
        self.last = None;
    }
    /// The message to send, or None when the host already has these values.
    fn next(&mut self, headroom: f32) -> Result<Option<DisplayCaps>, i32> {
        if !self.announced {
            return Err(MYSTIC_ERR_UNIMPLEMENTED);
        }
        let caps = caps(headroom);
        if self.last == Some(caps) {
            return Ok(None);
        }
        Ok(Some(caps))
    }
}

/// Reports the stream's display: 1 when sent, 0 when the host already has these values,
/// MYSTIC_ERR_UNIMPLEMENTED when the host does not take the message.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_display_caps(handle: *const MysticSession, headroom: f32) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let Some(session) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    let mut reports = handle.display.lock().unwrap_or_else(|e| e.into_inner());
    match reports.next(headroom) {
        Err(code) => code,
        Ok(None) => 0,
        Ok(Some(caps)) => match session.send(ClientMessage::DisplayCaps(caps)) {
            Ok(()) => {
                reports.last = Some(caps);
                1
            }
            Err(_) => MYSTIC_ERR_UNIMPLEMENTED,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headroom_estimates_a_peak_the_host_accepts() {
        let caps = caps(4.0);
        assert!(caps.hdr);
        assert_eq!(caps.max_centinits, 120_000, "300-nit SDR white times 4");
        assert_eq!(caps.max_average_centinits, 24_000, "20% of the peak");
        assert_eq!(caps.min_decimillinits, 10, "0.001 nits");
        assert_eq!(DisplayCaps::decode(&caps.encode()), Some(caps));
        let l = luminance(4.0).unwrap();
        assert!(l.estimated_from_ratio);
        assert_eq!(l.max_nits, 1200.0);
    }

    #[test]
    fn sdr_and_unusable_headroom_send_no_luminance() {
        for headroom in [1.0, 0.5, f32::NAN, f32::INFINITY, -2.0] {
            assert_eq!(caps(headroom), DisplayCaps { hdr: false, ..Default::default() }, "{headroom}");
            assert!(headroom > 1.0 || luminance(headroom).is_none());
        }
        // Beyond 10 000 nits the estimate is refused, but the display still shows HDR.
        assert_eq!(caps(40.0), DisplayCaps { hdr: true, ..Default::default() });
        assert!(luminance(40.0).is_none());
    }

    #[test]
    fn reports_need_the_announcement_and_skip_repeats() {
        let mut reports = DisplayReports::default();
        assert_eq!(reports.next(4.0), Err(MYSTIC_ERR_UNIMPLEMENTED));
        reports.announce(&[0x5508, DISPLAY_CAPS_MESSAGE_TYPE]);
        let first = reports.next(4.0).unwrap().unwrap();
        reports.last = Some(first);
        assert_eq!(reports.next(4.0), Ok(None));
        assert_eq!(reports.next(2.0).unwrap().map(|c| c.max_centinits), Some(60_000));
        reports.announce(&[DISPLAY_CAPS_MESSAGE_TYPE]);
        assert_eq!(reports.next(4.0), Ok(Some(first)), "a new stream reports again");
        reports.announce(&[]);
        assert_eq!(reports.next(4.0), Err(MYSTIC_ERR_UNIMPLEMENTED));
    }

    #[test]
    fn the_c_entry_point_refuses_without_a_stream() {
        unsafe {
            assert_eq!(mystic_session_display_caps(std::ptr::null(), 4.0), MYSTIC_ERR_INVALID_ARGUMENT);
            let handle = crate::mystic_session_new();
            assert_eq!(mystic_session_display_caps(handle, 4.0), MYSTIC_ERR_NOT_STARTED);
            crate::mystic_session_free(handle);
        }
    }
}
