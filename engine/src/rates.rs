//! Live rate changes over 0x553C: one bounded in-flight request by hand, whose matching host
//! answer is authoritative, and Nightjar's "Lower bitrate when frames are lost" controller
//! (`nightjar_policy::client_hint`, its desktop app's `rate_change.rs`), with one request of its
//! own in flight. The controller ticks with the stream doctor, once a second on the app's clock.
use crate::MysticSession;
use nightjar_core::control::{ClientMessage, ControlEvent};
use nightjar_policy::client_hint;
use nightjar_policy::stats::Stats;
use rubylight_protocol::rate_change::{Reason, Status, RateChangeRequest, RateChangeResult, RATE_CHANGE_MESSAGE_TYPE};
use serde_json::{json,Value};
use std::{ffi::c_char,time::{Duration,Instant}};

#[derive(Default)]
pub(crate) struct Rates {
    pub available: bool,
    serial: u32,
    pending: Option<(u32,Instant)>,
    result: Option<RateChangeResult>,
    error: Option<String>,
    hint: Hint,
}

/// The loss-based controller's state beside the requests by hand.
#[derive(Default)]
struct Hint {
    controller: Option<client_hint::Bitrate>,
    /// Its request in flight, with the tick time it went out.
    pending: Option<(u32,u64)>,
    /// The host's answer to it, taken at the next tick.
    answer: Option<RateChangeResult>,
    /// A change by hand set the bitrate; the controller's range follows at the next tick.
    overridden: Option<u32>,
    /// The serial of the newest result that set the bitrate, so an older one never undoes it.
    bitrate_serial: u32,
    kbps: u32,
    last_tick_ms: Option<u64>,
    /// Why the controller stopped, for the app.
    stopped: Option<String>,
}

/// What the loss-based controller did at a tick, for the app.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct HintState {
    pub active: bool,
    pub kbps: u32,
    pub stopped: Option<String>,
}

fn reason_text(reason: Reason) -> &'static str {
    match reason {
        Reason::Invalid => "the request was not valid",
        Reason::Disabled => "the PC does not change this stream's rates",
        Reason::Codec => "this stream's codec keeps its rates",
        Reason::HostLimit => "the PC's limit",
        Reason::EncoderLimit => "the encoder's limit",
        Reason::EncoderFailed => "the encoder could not run at it",
        Reason::Superseded => "a later change replaced it",
        _ => "the PC refused it",
    }
}

impl Rates {
    pub fn announce(&mut self,messages:&[u16]) { self.available=messages.contains(&RATE_CHANGE_MESSAGE_TYPE); }
    fn next_serial(&mut self) -> u32 {
        self.serial=self.serial.wrapping_add(1).max(1);
        self.serial
    }
    fn request(&mut self,kbps:u32,fps:u32,now:Instant) -> Result<RateChangeRequest,String> {
        self.expire(now);
        if !self.available { return Err("This stream does not offer live frame-rate controls.".into()); }
        if self.pending.is_some() { return Err("A rate change is already waiting for the host.".into()); }
        let request=RateChangeRequest {serial:self.serial.wrapping_add(1).max(1),bitrate_kbps:kbps,fps_millihz:fps};
        if !request.valid() || kbps > 150_000 || fps > 240_000 { return Err("Choose 1–150 Mbps and 10–240 fps; zero leaves a field unchanged.".into()); }
        let serial=self.next_serial();
        self.pending=Some((serial,now));self.result=None;self.error=None;
        Ok(request)
    }
    /// Starts the loss-based controller from the stream's bitrate, under this client's cap
    /// `limit_kbps` (0 for none). Only a stream that takes 0x553C has one.
    pub fn start_hint(&mut self,kbps:u32,limit_kbps:u32,now_ms:u64) -> bool {
        if !self.available || kbps == 0 { return false; }
        self.hint=Hint { controller:Some(client_hint::Bitrate::new(kbps,limit_kbps,now_ms)),kbps,..Hint::default() };
        true
    }
    /// One tick of the loss-based controller: the host's answers since the last, then its
    /// request, if it wants a change. A change by hand in flight goes first.
    pub fn hint_tick(&mut self,stats:&Stats) -> Option<RateChangeRequest> {
        let now_ms=stats.now_ms;
        let hint=&mut self.hint;
        let controller=hint.controller.as_mut()?;
        if let Some(kbps)=hint.overridden.take() {
            hint.kbps=kbps;
            controller.overridden(kbps,now_ms);
        }
        if let Some(result)=hint.answer.take() {
            let newest=hint.bitrate_serial == 0 || (result.serial.wrapping_sub(hint.bitrate_serial) as i32) > 0;
            if result.bitrate_kbps > 0 && newest { hint.bitrate_serial=result.serial;hint.kbps=result.bitrate_kbps; }
            if matches!(result.bitrate.status,Status::Applied | Status::Clamped) {
                controller.applied(hint.kbps,now_ms);
            } else if result.bitrate.reason == Reason::Superseded {
                controller.overridden(hint.kbps,now_ms);
            } else {
                controller.refused();
                hint.stopped=Some(format!("Loss-based bitrate stopped: {}",reason_text(result.bitrate.reason)));
            }
        }
        if hint.pending.is_some_and(|(_,sent)|now_ms >= sent+5000) {
            hint.pending=None;controller.refused();
            hint.stopped=Some("Loss-based bitrate stopped: the PC did not answer".into());
        }
        if self.pending.is_some() || hint.pending.is_some() { return None; }
        if hint.last_tick_ms.is_some_and(|at|now_ms < at+1000) { return None; }
        hint.last_tick_ms=Some(now_ms);
        let kbps=hint.controller.as_mut()?.sample(stats)?;
        let serial=self.next_serial();
        self.hint.pending=Some((serial,now_ms));
        Some(RateChangeRequest {serial,bitrate_kbps:kbps,fps_millihz:0})
    }
    /// The controller's request could not be sent: it stops, as for a refusal.
    pub fn hint_send_failed(&mut self,error:&str) {
        self.hint.pending=None;
        if let Some(controller)=&mut self.hint.controller { controller.refused(); }
        self.hint.stopped=Some(format!("Loss-based bitrate stopped: {error}"));
    }
    pub fn hint_state(&self) -> Option<HintState> {
        let controller=self.hint.controller.as_ref()?;
        Some(HintState {active:!controller.stopped(),kbps:self.hint.kbps,stopped:self.hint.stopped.clone()})
    }
    /// The controller can still raise the bitrate, so automatic quality waits.
    pub fn hint_has_room(&self) -> bool {
        self.hint.controller.as_ref().is_some_and(|c|!c.stopped() && c.current_kbps() < c.max_kbps())
    }
    pub fn receive(&mut self,event:ControlEvent) {
        if let ControlEvent::RateChange(result)=event {
            self.expire(Instant::now());
            if self.hint.pending.map(|p|p.0) == Some(result.serial) {
                self.hint.pending=None;self.hint.answer=Some(result);return;
            }
            if self.pending.map(|p|p.0) != Some(result.serial) { return; }
            self.pending=None;
            // A bitrate set by hand: the controller's range follows it, unless an older answer.
            let newest=self.hint.bitrate_serial == 0 || (result.serial.wrapping_sub(self.hint.bitrate_serial) as i32) > 0;
            if self.hint.controller.is_some() && result.bitrate_kbps > 0 && newest
                && matches!(result.bitrate.status,Status::Applied | Status::Clamped) {
                self.hint.bitrate_serial=result.serial;self.hint.overridden=Some(result.bitrate_kbps);
            }
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

/// Starts Nightjar's "Lower bitrate when frames are lost" on a stream that takes 0x553C, from
/// the stream's bitrate `kbps` under this client's cap `limit_kbps` (0 for none). It then ticks
/// with `mystic_session_health_tick`, whose answer carries its state. Returns 0, or
/// MYSTIC_ERR_UNIMPLEMENTED when the stream takes no rate changes.
///
/// # Safety
/// `handle` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_rate_hint_begin(handle:*const MysticSession,kbps:u32,limit_kbps:u32,now_ms:u64) -> i32 {
    let Some(h)=handle.as_ref() else { return crate::MYSTIC_ERR_INVALID_ARGUMENT; };
    if h.session.is_none() { return crate::MYSTIC_ERR_NOT_STARTED; }
    if !(1..=2_000_000).contains(&kbps) { return crate::MYSTIC_ERR_INVALID_ARGUMENT; }
    if h.rates.lock().unwrap_or_else(|e|e.into_inner()).start_hint(kbps,limit_kbps,now_ms) { crate::MYSTIC_OK } else { crate::MYSTIC_ERR_UNIMPLEMENTED }
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

    fn tick(now_ms:u64,loss:f32) -> Stats {
        Stats {now_ms,recent_video:true,loss_percent:Some(loss),queue_ms:Some(1.0),..Stats::default()}
    }
    fn answer(serial:u32,kbps:u32,bitrate:Outcome) -> ControlEvent {
        ControlEvent::RateChange(RateChangeResult {serial,bitrate_kbps:kbps,fps_millihz:60_000,bitrate,fps:Outcome::APPLIED})
    }

    #[test]
    fn loss_lowers_the_bitrate_and_the_host_answer_sets_it() {
        let mut r=Rates::default();
        assert!(!r.start_hint(20_000,0,0),"only a stream that takes 0x553C");
        r.announce(&[RATE_CHANGE_MESSAGE_TYPE]);
        assert!(r.start_hint(20_000,0,0));
        assert_eq!(r.hint_tick(&tick(1000,20.0)),None,"no decision in the first three seconds");
        let cut=r.hint_tick(&tick(3000,20.0)).expect("heavy loss cuts");
        assert_eq!(cut.bitrate_kbps,14_000);assert_eq!(cut.fps_millihz,0);
        assert_eq!(r.hint_tick(&tick(4000,20.0)),None,"one request in flight");
        r.receive(answer(cut.serial,14_000,Outcome::APPLIED));
        assert_eq!(r.hint_tick(&tick(5000,0.0)),None,"two seconds between changes");
        assert_eq!(r.hint_state(),Some(HintState {active:true,kbps:14_000,stopped:None}));
    }

    #[test]
    fn a_refusal_or_no_answer_stops_it_and_a_change_by_hand_moves_its_range() {
        let mut r=Rates::default();r.announce(&[RATE_CHANGE_MESSAGE_TYPE]);
        r.start_hint(20_000,0,0);
        let cut=r.hint_tick(&tick(3000,20.0)).unwrap();
        r.receive(answer(cut.serial,20_000,Outcome {status:Status::Refused,reason:Reason::Disabled}));
        assert_eq!(r.hint_tick(&tick(4000,20.0)),None);
        let state=r.hint_state().unwrap();
        assert!(!state.active);assert!(state.stopped.unwrap().contains("does not change"));

        r.start_hint(20_000,0,0);
        r.hint_tick(&tick(3000,20.0)).unwrap();
        assert_eq!(r.hint_tick(&tick(8000,20.0)),None);
        assert!(r.hint_state().unwrap().stopped.unwrap().contains("did not answer"));

        r.start_hint(20_000,0,0);
        let by_hand=r.request(30_000,0,Instant::now()).unwrap();
        assert_eq!(r.hint_tick(&tick(3000,20.0)),None,"a change by hand goes first");
        r.receive(answer(by_hand.serial,30_000,Outcome::APPLIED));
        assert_eq!(r.hint_tick(&tick(4000,0.0)),None);
        assert_eq!(r.hint_state().unwrap().kbps,30_000);
    }
}
