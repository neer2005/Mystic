//! One bounded in-flight request; only its matching host answer is authoritative.
use crate::MysticSession;
use nightjar_core::control::{ClientMessage, ControlEvent};
use rubylight_protocol::rate_change::{RateChangeRequest, RateChangeResult, RATE_CHANGE_MESSAGE_TYPE};
use serde_json::{json,Value};
use std::{ffi::c_char,time::{Duration,Instant}};

#[derive(Default)]
pub(crate) struct Rates {
    pub available: bool,
    serial: u32,
    pending: Option<(u32,Instant)>,
    result: Option<RateChangeResult>,
    error: Option<String>,
}
impl Rates {
    pub fn announce(&mut self,messages:&[u16]) { self.available=messages.contains(&RATE_CHANGE_MESSAGE_TYPE); }
    fn request(&mut self,kbps:u32,fps:u32,now:Instant) -> Result<RateChangeRequest,String> {
        self.expire(now);
        if !self.available { return Err("This stream does not offer live frame-rate controls.".into()); }
        if self.pending.is_some() { return Err("A rate change is already waiting for the host.".into()); }
        let serial=self.serial.wrapping_add(1).max(1);
        let request=RateChangeRequest {serial,bitrate_kbps:kbps,fps_millihz:fps};
        if !request.valid() || kbps > 150_000 || fps > 240_000 { return Err("Choose 1–150 Mbps and 10–240 fps; zero leaves a field unchanged.".into()); }
        self.serial=serial;self.pending=Some((serial,now));self.result=None;self.error=None;
        Ok(request)
    }
    pub fn receive(&mut self,event:ControlEvent) {
        if let ControlEvent::RateChange(result)=event {
            self.expire(Instant::now());
            if self.pending.map(|p|p.0) != Some(result.serial) { return; }
            self.pending=None;
            if !(1..=150_000).contains(&result.bitrate_kbps) || !(10_000..=240_000).contains(&result.fps_millihz) {
                self.error=Some("The host returned rates outside Mystic's supported range.".into());return;
            }
            self.result=Some(result);
        }
    }
    fn expire(&mut self,now:Instant) {
        if self.pending.is_some_and(|(_,at)|now.saturating_duration_since(at) >= Duration::from_secs(5)) {
            self.pending=None;self.error=Some("The host did not answer within 5 seconds. Applied rates are unknown; refresh before retrying.".into());
        }
    }
    fn snapshot(&mut self,now:Instant) -> Value {
        self.expire(now);
        let result=self.result.map(|r|json!({"kbps":r.bitrate_kbps,"fpsMilliHz":r.fps_millihz,
            "bitrateStatus":r.bitrate.status as u8,"bitrateReason":r.bitrate.reason as u8,
            "fpsStatus":r.fps.status as u8,"fpsReason":r.fps.reason as u8}));
        json!({"available":self.available,"pending":self.pending.is_some(),"result":result,"error":self.error})
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_session_rates(handle:*const MysticSession,kbps:u32,fps:u32) -> *mut c_char {
    crate::host::envelope((|| {
        let h=handle.as_ref().ok_or("No stream is running.")?;
        let session=h.session.as_ref().ok_or("No stream is running.")?;
        if kbps != 0 || fps != 0 {
            let request=h.rates.lock().unwrap_or_else(|e|e.into_inner()).request(kbps,fps,Instant::now())?;
            if session.send(ClientMessage::RateChange(request)).is_err() {
                let mut state=h.rates.lock().unwrap_or_else(|e|e.into_inner());
                state.pending=None;state.error=Some("The stream did not accept the rate request.".into());
            }
        }
        Ok(h.rates.lock().unwrap_or_else(|e|e.into_inner()).snapshot(Instant::now()))
    })())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rubylight_protocol::rate_change::Outcome;
    #[test]
    fn negotiation_serials_timeout_and_stale_answers_are_bounded() {
        let mut r=Rates::default();let now=Instant::now();
        assert!(r.request(40_000,60_000,now).is_err());r.announce(&[RATE_CHANGE_MESSAGE_TYPE]);
        assert!(r.request(150_001,60_000,now).is_err());
        let first=r.request(40_000,60_000,now).unwrap();
        assert!(r.request(30_000,0,now).is_err());r.snapshot(now+Duration::from_secs(6));
        assert!(r.pending.is_none());assert!(r.error.is_some());
        let next=r.request(30_000,60_000,now).unwrap();
        let answer=|serial|ControlEvent::RateChange(RateChangeResult {serial,bitrate_kbps:28_000,fps_millihz:59_940,bitrate:Outcome::APPLIED,fps:Outcome::APPLIED});
        r.receive(answer(first.serial));assert!(r.result.is_none());
        r.receive(answer(next.serial));assert_eq!(r.result.unwrap().fps_millihz,59_940);
        assert!(r.pending.is_none());
    }
}
