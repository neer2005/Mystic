//! Additive host-control bridge: protocol and certificate verification remain in Nightjar.
use nightjar_core::http::{Feature, AppControl, ClientIdentity, HostClient, LaunchRequest, PairResult};
use rand_core::{OsRng, RngCore};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::sync::Arc;

struct HostError { message: String, retryable: bool }
impl From<String> for HostError {
    fn from(message: String) -> Self { Self { message, retryable: false } }
}
impl From<&str> for HostError {
    fn from(message: &str) -> Self { message.to_owned().into() }
}
impl From<nightjar_core::http::Error> for HostError {
    fn from(error: nightjar_core::http::Error) -> Self {
        let retryable = matches!(&error, nightjar_core::http::Error::Io(e)
            if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::ConnectionRefused
                | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
                | std::io::ErrorKind::NotConnected | std::io::ErrorKind::BrokenPipe
                | std::io::ErrorKind::NetworkUnreachable | std::io::ErrorKind::HostUnreachable
                | std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::AddrNotAvailable));
        Self { message: error.to_string(), retryable }
    }
}
fn host_envelope(result: Result<Value, HostError>) -> *mut c_char {
    match result {
        Ok(value) => envelope(Ok(value)),
        Err(error) => CString::new(json!({"ok":false,"error":error.message,"retryable":error.retryable}).to_string())
            .expect("JSON contains no literal NUL").into_raw(),
    }
}

pub struct MysticHost {
    client: HostClient,
}
fn envelope(result: Result<Value, String>) -> *mut c_char {
    let value = match result {
        Ok(v) => json!({"ok": true, "value": v}),
        Err(e) => json!({"ok": false, "error": e}),
    };
    CString::new(value.to_string())
        .expect("JSON contains no literal NUL")
        .into_raw()
}
unsafe fn text<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err("required string is null".into());
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| "invalid UTF-8".into())
}
fn identity(v: &Value) -> Result<ClientIdentity, String> {
    ClientIdentity::from_pem(
        field(v, "uniqueID")?,
        field(v, "certificate")?,
        field(v, "privateKey")?,
    )
    .map_err(|e| e.to_string())
}
fn field<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing {key}"))
}
#[no_mangle]
pub extern "C" fn mystic_identity_create() -> *mut c_char {
    envelope(ClientIdentity::generate().map(|i| json!({"uniqueID": i.unique_id(), "certificate":i.certificate_pem(), "privateKey":i.private_key_pem()})).map_err(|e|e.to_string()))
}
#[no_mangle]
pub unsafe extern "C" fn mystic_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_host_new(
    address: *const c_char,
    port: u16,
    stored: *const c_char,
    certificate: *const c_char,
    error: *mut c_char,
    capacity: usize,
) -> *mut MysticHost {
    let result: Result<MysticHost, String> = (|| {
        if port == 0 {
            return Err("HTTP port must be nonzero".into());
        }
        let v: Value = serde_json::from_str(text(stored)?)
            .map_err(|_| "invalid stored identity".to_owned())?;
        let mut client = HostClient::new(text(address)?, port, Arc::new(identity(&v)?))
            .map_err(|e| e.to_string())?
            .with_device_name("Mystic");
        if !certificate.is_null() {
            client = client
                .with_server_certificate_pem(text(certificate)?)
                .map_err(|e| e.to_string())?;
        }
        Ok(MysticHost { client })
    })();
    match result {
        Ok(h) => Box::into_raw(Box::new(h)),
        Err(e) => {
            super::write_error(error, capacity, &e);
            std::ptr::null_mut()
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_host_free(host: *mut MysticHost) {
    if !host.is_null() {
        drop(Box::from_raw(host));
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_host_cancel(host: *const MysticHost) {
    if let Some(h) = host.as_ref() {
        h.client.cancel_pending_requests();
    }
}
#[no_mangle]
pub unsafe extern "C" fn mystic_host_request(
    host: *const MysticHost,
    operation: *const c_char,
    request: *const c_char,
) -> *mut c_char {
    host_envelope((|| {
        let host = host.as_ref().ok_or("null host")?;
        let request: Value =
            serde_json::from_str(text(request)?).map_err(|_| "invalid request JSON")?;
        host.request(text(operation)?, request)
    })())
}
impl MysticHost {
    fn info(&self) -> Result<nightjar_core::http::ServerInfo, HostError> {
        // Never use Nightjar's HTTP fallback for an already pinned host.
        if self.client.server_certificate_pem().is_some() {
            self.client.server_info_https()
        } else {
            self.client.server_info_http(true)
        }
        .map_err(HostError::from)
    }
    fn request(&self, operation: &str, v: Value) -> Result<Value, HostError> {
        match operation {
            "info" => {
                let i = self.info()?;
                Ok(host_info_value(&i, self.client.server_certificate_pem().is_some()))
            }
            "pair" => {
                let pin = field(&v, "pin")?;
                if pin.len() != 4 || !pin.bytes().all(|b| b.is_ascii_digit()) {
                    return Err("PIN must be four digits".into());
                }
                let i = self.info()?;
                match self.client.pair(&i, pin).map_err(HostError::from)? {
                    PairResult::Paired {
                        server_certificate_pem,
                    } => Ok(json!({"certificate":server_certificate_pem,"uniqueID":i.unique_id})),
                    PairResult::PinWrong => {
                        Err("The PIN entered on the host did not match.".into())
                    }
                    PairResult::AlreadyInProgress => {
                        Err("Another device is pairing. Try again when it finishes.".into())
                    }
                    PairResult::Failed(reason) => Err(format!("Pairing failed: {reason:?}").into()),
                }
            }
            "apps" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                let apps = self
                    .client
                    .app_list(&i.capabilities)
                    .map_err(HostError::from)?;
                Ok(Value::Array(apps.into_iter().filter(|a| a.control == AppControl::None).map(|a|json!({"id":a.id,"name":a.name,"uuid":a.uuid,"hdrSupported":a.hdr_supported})).collect()))
            }
            "bitrate" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::RuntimeBitrate) { return Err("This host does not support live bitrate changes.".into()); }
                let kbps = v["kbps"].as_u64().filter(|v| (1..=150_000).contains(v)).ok_or("invalid bitrate")? as u32;
                let applied = self.client.set_bitrate(kbps).map_err(HostError::from)?;
                Ok(json!({"kbps":applied}))
            }
            "launch" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                let app_id = v["appID"]
                    .as_i64()
                    .and_then(|n| i32::try_from(n).ok())
                    .filter(|n| *n > 0)
                    .ok_or("invalid app ID")?;
                let width = dimension(&v, "width", 7680)?;
                let height = dimension(&v, "height", 4320)?;
                let fps = dimension(&v, "fps", 240)?;
                let hdr = v["hdr"].as_bool().unwrap_or(false);
                if v["resumeOnly"].as_bool().unwrap_or(false) && i.current_game != app_id {
                    return Err("The original app is no longer running on the host.".into());
                }
                // Refuse to replace an unrelated running application.
                if i.current_game != 0 && i.current_game != app_id {
                    return Err("A different app is running on the host. End it on the host before launching another.".into());
                }
                let mut key = [0; 16];
                OsRng.fill_bytes(&mut key);
                let key_id = OsRng.next_u32() as i32;
                let audio = match (v["channelCount"].as_u64().unwrap_or(2), v["channelMask"].as_u64().unwrap_or(3)) {
                    (2,3) => nightjar_core::sdp::AudioConfiguration::STEREO,
                    (6,0x3f) => nightjar_core::sdp::AudioConfiguration::SURROUND_51,
                    (8,0x63f) => nightjar_core::sdp::AudioConfiguration::SURROUND_71,
                    _ => return Err("unsupported launch audio layout".into()),
                };
                let gamepad_mask = v["gamepadMask"].as_u64().unwrap_or(0);
                if gamepad_mask > 15 { return Err("invalid controller mask (maximum four controllers)".into()); }
                let request = LaunchRequest {
                    gamepad_mask: gamepad_mask as u32,
                    app_id,
                    app_uuid: v["appUUID"].as_str().unwrap_or("").into(),
                    width,
                    height,
                    fps,
                    hdr,
                    audio,
                    ri_key: key,
                    ri_key_id: key_id,
                    ..Default::default()
                };
                let result = if i.current_game == app_id {
                    self.client.resume(&request, &i)
                } else {
                    self.client.launch(&request, &i)
                }
                .map_err(HostError::from)?;
                let launched = result.ok_or("The host declined to start the stream.")?;
                let mut iv = [0u8; 16];
                iv[..4].copy_from_slice(&key_id.to_be_bytes());
                Ok(
                    json!({"rtspURL":launched.rtsp_session_url,"appVersion":i.app_version,
                    "codecSupport":i.server_codec_mode_support,"key":key,"iv":iv,
                    "runtimeBitrate":i.capabilities.has(Feature::RuntimeBitrate)}),
                )
            }
            _ => Err("unknown host operation".into()),
        }
    }
}
fn host_info_value(i: &nightjar_core::http::ServerInfo, has_local_pin: bool) -> Value {
    // Another address can recognize our identity without having a local certificate pin.
    // Offer PIN pairing for that endpoint instead of attempting unpinned HTTPS.
    json!({"name":i.hostname,"uniqueID":i.unique_id,"paired":i.paired && has_local_pin,
        "appVersion":i.app_version,"codecSupport":i.server_codec_mode_support,"currentGame":i.current_game})
}
fn dimension(v: &Value, name: &str, max: u32) -> Result<u32, String> {
    v[name]
        .as_u64()
        .filter(|n| *n > 0 && *n <= u64::from(max))
        .map(|n| n as u32)
        .ok_or_else(|| format!("invalid {name}"))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_transport_errors_allow_a_recovery_retry() {
        assert!(HostError::from(nightjar_core::http::Error::Io(std::io::ErrorKind::TimedOut.into())).retryable);
        assert!(!HostError::from(nightjar_core::http::Error::CertificateMismatch).retryable);
        assert!(!HostError::from(nightjar_core::http::Error::NotPaired).retryable);
        assert!(!HostError::from(nightjar_core::http::Error::Status { code: 401, message: "denied".into() }).retryable);
    }
    #[test]
    fn paired_alias_requires_its_own_local_pin() {
        let mut info = nightjar_core::http::ServerInfo::parse(
            r#"<root status_code="200"><hostname>PC</hostname><uniqueid>host1</uniqueid><PairStatus>1</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>"#, 47989,
        ).unwrap();
        assert_eq!(host_info_value(&info, false)["paired"], false);
        assert_eq!(host_info_value(&info, true)["paired"], true);
        assert_eq!(host_info_value(&info, false)["uniqueID"], "host1");
        info.paired = false;
        assert_eq!(host_info_value(&info, true)["paired"], false);
    }
    #[test]
    fn identity_round_trip_and_bad_arguments() {
        unsafe {
            let p = mystic_identity_create();
            let v: Value = serde_json::from_str(CStr::from_ptr(p).to_str().unwrap()).unwrap();
            assert_eq!(v["ok"], true);
            let i = identity(&v["value"]).unwrap();
            assert_eq!(i.unique_id(), v["value"]["uniqueID"].as_str().unwrap());
            mystic_string_free(p);
            let result = mystic_host_request(std::ptr::null(), std::ptr::null(), std::ptr::null());
            let v: Value = serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap();
            assert_eq!(v["ok"], false);
            mystic_string_free(result);
        }
        assert!(dimension(&json!({"width":-1}), "width", 7680).is_err());
        assert!(dimension(&json!({"width":7681}), "width", 7680).is_err());
    }
}
