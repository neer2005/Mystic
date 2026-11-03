//! Nightjar's stream doctor: nightjar-policy's `StreamHealth` and `BitrateTrial`, the code
//! Android's and the desktop client's "Why did my stream stutter?" run. The app feeds one tick a
//! second with the timings it measures; the engine adds loss, round trip, jitter and late frames.
//! Calls are serialized by the session's owner, like the bitrate policy.
use crate::{host::envelope, MysticSession};
use nightjar_core::control::ConnectionStatus;
use nightjar_policy::health::{BitrateTrial, Report, StreamHealth, TrialOffer, TrialRefused};
use nightjar_policy::stats::Stats;
use serde_json::{json, Value};
use std::ffi::c_char;

#[derive(Default)]
pub(crate) struct Doctor {
    health: StreamHealth,
    trial: BitrateTrial,
    completed: u64,
    drops: u64,
}

/// A measurement the app passes, or `None` for NaN and negative values.
fn measured(value: f32) -> Option<f32> {
    (value.is_finite() && value >= 0.0).then_some(value)
}

fn report_value(report: &Report, offer: TrialOffer) -> Value {
    json!({
        "findings": report.findings.iter().map(|f| f.name()).collect::<Vec<_>>(),
        "samples": report.samples, "recent": report.recent,
        "worstLossPercent": report.worst_loss_percent, "worstDecodeMs": report.worst_decode_ms,
        "worstHostP95Ms": report.worst_host_p95_ms, "worstDisplayP95Ms": report.worst_display_p95_ms,
        "stalls": report.stalls, "stallPeriodMs": report.stall_period_ms,
        "hostIncludesSend": report.host_includes_send, "lateSamples": report.late_samples,
        "offer": match offer { TrialOffer::None => "none", TrialOffer::Try => "try", TrialOffer::Undo => "undo" },
    })
}

/// One stats tick. `decode_ms`, `host_p95_ms` and `display_p95_ms` are the app's recent
/// timings, `released_fps` and `shown_fps` its decoded and enqueued rates (NaN when unknown),
/// `thermal_level` 0 normal, 1 warm, 2 and up hot; `interval_ms` is the time since the previous tick. Returns the network figures for the overlay.
///
/// # Safety
/// `p` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_health_tick(
    p: *mut MysticSession,
    decode_ms: f32,
    host_p95_ms: f32,
    display_p95_ms: f32,
    released_fps: f32,
    shown_fps: f32,
    thermal_level: u32,
    interval_ms: u32,
    now_ms: u64,
) -> *mut c_char {
    envelope((|| {
        let p = p.as_mut().ok_or("No stream is running.")?;
        let session = p.session.as_ref().ok_or("No stream is running.")?;
        let stats = session.stats();
        let doctor = &mut p.doctor;
        let completed = stats.video.frames_completed.saturating_sub(doctor.completed);
        let drops = stats.video.frame_drops.saturating_sub(doctor.drops);
        doctor.completed = stats.video.frames_completed;
        doctor.drops = stats.video.frame_drops;
        let mut network = p.network.lock().unwrap_or_else(|e| e.into_inner());
        let received = std::mem::take(&mut network.received);
        let received_bytes = std::mem::take(&mut network.received_bytes);
        let queue_ms = network.take_queue_ms();
        let seconds = f64::from(interval_ms.max(1)) / 1000.0;
        let tick = Stats {
            now_ms,
            recent_video: received > 0,
            poor_connection: stats.connection_status == Some(ConnectionStatus::Poor),
            fps: network.fps,
            loss_percent: (completed + drops > 0).then(|| drops as f32 * 100.0 / (completed + drops) as f32),
            decode_ms: measured(decode_ms),
            jitter_ms: network.jitter,
            host_p95_ms: measured(host_p95_ms),
            display_p95_ms: measured(display_p95_ms),
            received_fps: Some((received as f64 / seconds) as f32),
            released_fps: measured(released_fps),
            shown_fps: measured(shown_fps),
            late_frames: Some(network.late.tick()),
            queue_ms,
            thermal_level,
            ..Stats::default()
        };
        drop(network);
        doctor.health.add(&tick);
        // Nightjar's loss-based bitrate ticks with these figures, when the app started it.
        let hint = {
            let mut rates = p.rates.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(request) = rates.hint_tick(&Stats {
                now_ms, recent_video: tick.recent_video, poor_connection: tick.poor_connection,
                loss_percent: tick.loss_percent, queue_ms, ..Stats::default()
            }) {
                if let Err(error) = session.send(nightjar_core::control::ClientMessage::RateChange(request)) {
                    rates.hint_send_failed(&error.to_string());
                }
            }
            rates.hint_state()
        };
        p.last_tick = Some(tick);
        let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
        Ok(json!({
            "rttMs": stats.rtt.map(|(rtt, _)| ms(rtt)), "rttVarianceMs": stats.rtt.map(|(_, var)| ms(var)),
            "lossPercent": tick.loss_percent, "jitterMs": tick.jitter_ms, "receivedFps": tick.received_fps,
            "poorConnection": tick.poor_connection, "inputHeld": stats.input_contact_lost,
            // This tick's frames, for the report a Foundation host's bitrate controller takes.
            "completedFrames": completed, "droppedFrames": drops,
            "videoMbps": received_bytes as f64 * 8.0 / seconds / 1_000_000.0,
            "queueMs": tick.queue_ms,
            // Loss-based bitrate (`mystic_session_rate_hint_begin`): null when not started.
            "hint": hint.map(|h| json!({"active": h.active, "kbps": h.kbps, "stopped": h.stopped})),
        }))
    })())
}

/// The report over the last 30 seconds and the trial it offers. `current_kbps` is the stream's
/// bitrate as far as the app knows it, `runtime_bitrate` whether the host changes it mid-stream,
/// `automatic` whether automatic bitrate owns it and `busy` whether a host action is in flight.
///
/// # Safety
/// `p` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_health_report(
    p: *mut MysticSession,
    now_ms: u64,
    current_kbps: u32,
    runtime_bitrate: bool,
    automatic: bool,
    busy: bool,
) -> *mut c_char {
    envelope((|| {
        let p = p.as_mut().ok_or("No stream is running.")?;
        let report = p.doctor.health.report(now_ms);
        let offer = p.doctor.trial.offer(report.can_suggest_bitrate(), current_kbps, runtime_bitrate, automatic, busy);
        Ok(report_value(&report, offer))
    })())
}

/// The bitrate a trial step asks the host for, from the host's live encoder bitrate (0 when
/// unknown): 20 % lower, or back to the original for `undo`. Negative when refused: -1 the host
/// reported no live bitrate (the trial is kept), -2 already at the minimum, -3 the bitrate was
/// changed by something else (both drop the trial).
///
/// # Safety
/// `p` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_trial_begin(p: *mut MysticSession, undo: bool, live_kbps: u32) -> i64 {
    let Some(p) = p.as_mut() else { return -1 };
    match p.doctor.trial.begin(undo, live_kbps) {
        Ok(kbps) => i64::from(kbps),
        Err(TrialRefused::Unavailable) => -1,
        Err(TrialRefused::Minimum) => -2,
        Err(TrialRefused::Replaced) => -3,
    }
}

/// Records what the host applied for a trial step that started from `previous_kbps`.
///
/// # Safety
/// `p` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_trial_applied(p: *mut MysticSession, undo: bool, previous_kbps: u32, applied_kbps: u32) {
    if let Some(p) = p.as_mut() {
        p.doctor.trial.applied(undo, previous_kbps, applied_kbps);
    }
}

/// Drops the trial when automatic bitrate or a manual change takes over.
///
/// # Safety
/// `p` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_trial_clear(p: *mut MysticSession) {
    if let Some(p) = p.as_mut() {
        p.doctor.trial.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nightjar_policy::health::Finding;

    #[test]
    fn reports_carry_findings_evidence_and_the_offer() {
        let mut health = StreamHealth::default();
        for n in 1..=5 {
            health.add(&Stats { now_ms: n * 1000, recent_video: true, fps: 60, loss_percent: Some(6.0), jitter_ms: Some(1.0),
                decode_ms: Some(2.0), received_fps: Some(60.0), released_fps: Some(60.0), shown_fps: Some(60.0), ..Stats::default() });
        }
        let report = health.report(5000);
        assert!(report.findings.contains(&Finding::Network));
        let value = report_value(&report, BitrateTrial::default().offer(report.can_suggest_bitrate(), 20_000, true, false, false));
        assert_eq!(value["findings"][0], "NETWORK");
        assert_eq!(value["offer"], "try");
        assert_eq!(value["samples"], 5);
        let automatic = BitrateTrial::default().offer(report.can_suggest_bitrate(), 20_000, true, true, false);
        assert_eq!(report_value(&report, automatic)["offer"], "none", "automatic bitrate owns the rate");
    }

    #[test]
    fn trial_steps_and_refusals_cross_the_boundary() {
        unsafe {
            let session = crate::mystic_session_new();
            assert_eq!(mystic_session_trial_begin(session, false, 0), -1);
            assert_eq!(mystic_session_trial_begin(session, false, 400), -2);
            assert_eq!(mystic_session_trial_begin(session, false, 20_000), 16_000);
            mystic_session_trial_applied(session, false, 20_000, 16_000);
            assert_eq!(mystic_session_trial_begin(session, true, 16_000), 20_000);
            assert_eq!(mystic_session_trial_begin(session, true, 18_000), -3, "another change replaced the trial");
            crate::mystic_session_free(session);
        }
    }
}
