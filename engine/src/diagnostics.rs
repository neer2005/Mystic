//! Diagnostics shared with Nightjar: the overlay's health mark and hardware poll
//! (`nightjar_policy::overlay`), the host's hardware readings and remote access check as JSON,
//! and the redaction Nightjar's log file and problem reports use (`report::redact`).
use nightjar_core::http::{HardwareMetrics, NetworkPath, RemoteCheck, RemoteOutcome, Readings};
use nightjar_policy::overlay::{health, HardwareAnswer, HardwarePoll, Health};
use serde_json::{json, Map, Value};
use std::ffi::{c_char, CStr, CString};

fn measured(value: f32) -> Option<f32> { (value.is_finite() && value >= 0.0).then_some(value) }

/// The Compact line's mark: 0 unknown, 1 good, 2 fair, 3 poor. NaN for anything unmeasured.
#[no_mangle]
pub extern "C" fn mystic_overlay_health(shown_fps: f32, received_fps: f32, network_ms: f32, loss_percent: f32, decode_ms: f32) -> u8 {
    match health(measured(shown_fps), measured(received_fps), measured(network_ms), measured(loss_percent), measured(decode_ms)) {
        Health::Unknown => 0,
        Health::Good => 1,
        Health::Fair => 2,
        Health::Poor => 3,
    }
}

pub struct MysticHardwarePoll(HardwarePoll);

#[no_mangle]
pub extern "C" fn mystic_hardware_poll_new() -> *mut MysticHardwarePoll { Box::into_raw(Box::new(MysticHardwarePoll(HardwarePoll::default()))) }
/// # Safety
/// `poll` comes from `mystic_hardware_poll_new` and is not used afterwards; null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn mystic_hardware_poll_free(poll: *mut MysticHardwarePoll) {
    if !poll.is_null() { drop(Box::from_raw(poll)); }
}
/// The request generation to send now, or -1. `wanted`: the overlay shows host readings.
/// # Safety
/// `poll` is a live poll.
#[no_mangle]
pub unsafe extern "C" fn mystic_hardware_poll_due(poll: *mut MysticHardwarePoll, now_ms: u64, wanted: bool) -> i64 {
    poll.as_mut().and_then(|p| p.0.due(now_ms, wanted)).map_or(-1, i64::from)
}
/// `kind` 0 a sample (with its time and interval), 1 failed, 2 the host offers none. Returns
/// whether to show the sample.
/// # Safety
/// `poll` is a live poll.
#[no_mangle]
pub unsafe extern "C" fn mystic_hardware_poll_answered(poll: *mut MysticHardwarePoll, generation: u32, now_ms: u64, kind: u8,
                                                       sampled_at_unix_ms: i64, interval_ms: u32) -> bool {
    let answer = match kind {
        0 => HardwareAnswer::Sample { sampled_at_unix_ms, interval_ms },
        2 => HardwareAnswer::Unavailable,
        _ => HardwareAnswer::Failed,
    };
    poll.as_mut().is_some_and(|p| p.0.answered(generation, now_ms, answer))
}
/// Whether the last sample may still show.
/// # Safety
/// `poll` is a live poll.
#[no_mangle]
pub unsafe extern "C" fn mystic_hardware_poll_fresh(poll: *const MysticHardwarePoll, now_ms: u64) -> bool {
    poll.as_ref().is_some_and(|p| p.0.fresh(now_ms))
}

/// Adds a PC's name or address to what the redaction hides from now on.
/// # Safety
/// `secret` is NUL-terminated or null.
#[no_mangle]
pub unsafe extern "C" fn mystic_redact_add_secret(secret: *const c_char) {
    if let Some(secret) = secret.as_ref().and_then(|_| CStr::from_ptr(secret).to_str().ok()).filter(|s| !s.is_empty()) {
        nightjar_core::report::redact::add_secret(secret);
    }
}
/// A log line without PC names, addresses, IDs, keys or PINs; free with `mystic_string_free`.
/// # Safety
/// `text` is NUL-terminated or null.
#[no_mangle]
pub unsafe extern "C" fn mystic_redact(text: *const c_char) -> *mut c_char {
    let text = if text.is_null() { String::new() } else { CStr::from_ptr(text).to_string_lossy().into_owned() };
    CString::new(nightjar_core::report::redact::scrub(&text).replace('\0', "")).unwrap_or_default().into_raw()
}

fn readings(readings: &Readings) -> Value {
    Value::Object(readings.iter().map(|(key, value)| (key.to_owned(), json!(value))).collect::<Map<_, _>>())
}
pub(crate) fn hardware_value(m: &HardwareMetrics) -> Value {
    json!({
        "available": true, "sampledAtUnixMs": m.sampled_at_unix_ms, "intervalMs": m.interval_ms, "cpu": readings(&m.cpu),
        "gpus": m.gpus.iter().map(|g| json!({"id": g.id, "name": g.name, "metrics": readings(&g.metrics)})).collect::<Vec<_>>(),
    })
}
pub(crate) fn remote_value(result: Result<RemoteCheck, nightjar_core::http::Error>) -> Value {
    use nightjar_core::http::Error;
    let check = match result {
        Ok(check) => check,
        Err(e @ (Error::NotPaired | Error::InvalidArgument(_))) => return json!({"outcome":"notPaired","error":e.to_string()}),
        Err(Error::Cancelled) => return json!({"outcome":"cancelled"}),
        Err(e) => return json!({"outcome":"unreachable","error":e.to_string()}),
    };
    let stats = json!({"latencyMs": check.stats.latency_ms(), "jitterMs": check.stats.jitter_ms(), "lossPercent": check.stats.loss_percent()});
    let (outcome, path, error) = match check.outcome {
        RemoteOutcome::Verified { path, .. } => match path {
            Ok(NetworkPath::Direct) => ("verified", "direct", None),
            Ok(NetworkPath::Relay) => ("verified", "relay", None),
            Ok(NetworkPath::PeerRelay) => ("verified", "peerRelay", None),
            Ok(NetworkPath::Unknown) | Err(nightjar_core::http::HostApiError::Unavailable { .. }) => ("verified", "unknown", None),
            Err(e) => ("verified", "unknown", Some(e.to_string())),
        },
        RemoteOutcome::WrongHost => ("wrongHost", "", Some("A different PC answered at this address.".to_owned())),
        RemoteOutcome::PairRevoked => ("pairRevoked", "", None),
        RemoteOutcome::PermissionDenied => ("permissionDenied", "", None),
        RemoteOutcome::Unreachable(e) => ("unreachable", "", Some(e.to_string())),
    };
    let mut value = json!({"outcome": outcome, "path": path, "error": error});
    if outcome == "verified" { value["stats"] = stats; }
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_follows_nightjar_and_nan_is_unmeasured() {
        assert_eq!(mystic_overlay_health(f32::NAN, f32::NAN, f32::NAN, f32::NAN, f32::NAN), 0);
        assert_eq!(mystic_overlay_health(60.0, 60.0, 8.0, 0.1, 2.0), 1);
        assert_eq!(mystic_overlay_health(f32::NAN, f32::NAN, 40.0, f32::NAN, f32::NAN), 2);
        assert_eq!(mystic_overlay_health(f32::NAN, f32::NAN, f32::NAN, 5.0, f32::NAN), 3);
    }

    #[test]
    fn the_poll_asks_at_once_then_waits_for_the_answer() {
        unsafe {
            let poll = mystic_hardware_poll_new();
            assert_eq!(mystic_hardware_poll_due(poll, 0, false), -1);
            let first = mystic_hardware_poll_due(poll, 1_000, true);
            assert!(first >= 0);
            assert_eq!(mystic_hardware_poll_due(poll, 1_500, true), -1, "one at a time");
            assert!(mystic_hardware_poll_answered(poll, first as u32, 1_200, 0, 100, 1_000));
            assert!(mystic_hardware_poll_fresh(poll, 6_100) && !mystic_hardware_poll_fresh(poll, 6_200));
            let second = mystic_hardware_poll_due(poll, 3_200, true);
            assert!(!mystic_hardware_poll_answered(poll, second as u32, 3_300, 2, 0, 0));
            assert_eq!(mystic_hardware_poll_due(poll, 60_000, true), -1, "a host without readings is not asked again");
            mystic_hardware_poll_free(poll);
            mystic_hardware_poll_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn readings_and_redaction() {
        let m = HardwareMetrics::parse(r#"{"version":1,"sampled_at_unix_ms":5,"interval_ms":1000,"cpu":{"cpu_usage_percent":41.6},
            "gpus":[{"id":0,"name":"Radeon","metrics":{"gpu_temperature_c":61.5}}]}"#).unwrap();
        let v = hardware_value(&m);
        assert_eq!(v["cpu"]["cpu_usage_percent"], 41.6);
        assert_eq!(v["gpus"][0]["metrics"]["gpu_temperature_c"], 61.5);
        assert_eq!(v["intervalMs"], 1000);
        unsafe {
            mystic_redact_add_secret(c"Big Dawg".as_ptr());
            let p = mystic_redact(c"Route to Big Dawg at 192.168.1.20 ok".as_ptr());
            let line = CStr::from_ptr(p).to_str().unwrap().to_owned();
            crate::host::mystic_string_free(p);
            assert!(!line.contains("Big Dawg") && !line.contains("192.168.1.20"), "{line}");
            assert!(line.starts_with("Route to ") && line.ends_with(" ok"), "{line}");
        }
    }

    #[test]
    fn a_check_without_pairing_says_so() {
        let v = remote_value(Err(nightjar_core::http::Error::NotPaired));
        assert_eq!(v["outcome"], "notPaired");
        assert_eq!(remote_value(Err(nightjar_core::http::Error::Cancelled))["outcome"], "cancelled");
    }
}
