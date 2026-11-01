//! Additive host-control bridge: protocol and certificate verification remain in Nightjar.
use nightjar_core::http::{Feature, AppControl, ClientIdentity, HostClient, LaunchRequest, PairResult};
use rand_core::{OsRng, RngCore};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::sync::Arc;

/// Nightjar's release at the pinned revision (Cargo.toml). Hosts see the engine they talk to;
/// the suffix says it runs inside Mystic.
const NIGHTJAR_RELEASE: &str = "4.0.1";
pub(crate) fn app_version() -> String {
    format!("{NIGHTJAR_RELEASE}+mystic.{}", env!("CARGO_PKG_VERSION"))
}

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
pub(crate) fn envelope(result: Result<Value, String>) -> *mut c_char {
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
    // Every request's User-Agent then reads `Nightjar/<version>`; the first call wins.
    nightjar_core::http::set_app_version(&app_version());
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
            "library" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::NativeApi) { return Ok(json!({"library":null})); }
                let library = self.client.library().map_err(HostError::from)?;
                Ok(json!({"library":library}))
            }
            "session" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::NativeApi) { return Ok(json!({"session":null})); }
                Ok(json!({"session":self.client.session().map_err(HostError::from)?}))
            }
            "sessionAction" => {
                use nightjar_core::http::native_api::session::ActionId;
                let action = match field(&v,"action")? {
                    "disconnect" => ActionId::Disconnect,
                    "end" => ActionId::End,
                    "close_game" => ActionId::CloseGame,
                    _ => return Err("Unsupported session action.".into()),
                };
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::NativeApi) { return Err("This host has no native session controls.".into()); }
                let current = self.client.session().map_err(HostError::from)?;
                validate_session_action(&json!(current),&v)?;
                Ok(json!({"session":self.client.session_action(action).map_err(HostError::from)?}))
            }
            "radeon" => {
                let i=self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::NativeApi) { return Ok(json!({"radeon":null})); }
                match self.client.radeon() {
                    Ok(panel) => Ok(json!({"radeon":panel})),
                    Err(error) if error.http_status() == Some(404) => Ok(json!({"radeon":null})),
                    Err(error) => Err(HostError::from(error)),
                }
            }
            "radeonWrite" | "radeonRestore" => {
                use nightjar_core::http::native_api::radeon::SettingsWrite;
                let session=self.client.session().map_err(HostError::from)?;
                let current=json!(session);
                if current["owner"] != "you" || current["owner"] != v["expectedOwner"]
                    || current["app"]["app_id"] != v["expectedAppID"]
                    || !matches!(current["state"].as_str(),Some("streaming" | "suspended")) {
                    return Err("The owned host session changed. Refresh before changing graphics settings.".into());
                }
                let panel=self.client.radeon().map_err(HostError::from)?;
                validate_radeon_write(&json!(panel),&v,operation == "radeonRestore")?;
                let updated=if operation == "radeonRestore" {
                    self.client.restore_radeon()
                } else {
                    let write: SettingsWrite=serde_json::from_value(v["write"].clone())
                        .map_err(|_| HostError::from("Invalid graphics setting value."))?;
                    self.client.write_radeon(&write)
                }.map_err(HostError::from)?;
                Ok(json!({"radeon":updated}))
            }
            "wakeTargets" => {
                let info=self.client.server_info_https().map_err(HostError::from)?;
                let mut macs=Vec::new();let mut broadcasts=Vec::new();
                if let Some(mac)=info.mac_address.filter(|m|crate::wake::magic(m).is_ok()) { macs.push(mac); }
                if info.capabilities.has(Feature::NativeApi) {
                    if let Ok(wake)=self.client.wake() {
                        for mac in wake.primary.iter().chain(wake.targets.iter().map(|t|&t.mac)) {
                            if macs.len() < 8 && crate::wake::magic(mac).is_ok() && !macs.contains(mac) { macs.push(mac.clone()); }
                        }
                        for ip in wake.targets.iter().flat_map(|t|&t.broadcasts) {
                            if broadcasts.len() < 16 && ip.parse::<std::net::Ipv4Addr>().is_ok() && !broadcasts.contains(ip) { broadcasts.push(ip.clone()); }
                        }
                    }
                }
                Ok(json!({"macs":macs,"broadcasts":broadcasts}))
            }
            "artwork" => {
                let id = v["appID"].as_i64().and_then(|id| i32::try_from(id).ok())
                    .filter(|id| *id > 0).ok_or("invalid app ID")?;
                let bytes = self.client.box_art(id).map_err(HostError::from)?;
                Ok(json!({"bytes":bytes}))
            }
            "clipboardRead" | "clipboardWrite" => {
                let i=self.client.server_info_https().map_err(HostError::from)?;
                let (read,write)=clipboard_permissions(&i);
                if operation == "clipboardRead" {
                    if !read { return Err("The host does not allow reading its clipboard.".into()); }
                    let text=self.client.clipboard().map_err(HostError::from)?;
                    crate::clipboard::validate_text(&text,crate::clipboard::MANUAL_LIMIT)?;
                    Ok(json!({"text":text}))
                } else {
                    if !write { return Err("The host does not allow setting its clipboard.".into()); }
                    let text=field(&v,"text")?;
                    crate::clipboard::validate_text(text,crate::clipboard::MANUAL_LIMIT)?;
                    self.client.send_clipboard(text).map_err(HostError::from)?;
                    Ok(json!({"sent":true}))
                }
            }
            "bitrate" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::RuntimeBitrate) { return Err("This host does not support live bitrate changes.".into()); }
                let kbps = v["kbps"].as_u64().filter(|v| (1..=150_000).contains(v)).ok_or("invalid bitrate")? as u32;
                let applied = self.client.set_bitrate(kbps).map_err(HostError::from)?;
                Ok(json!({"kbps":applied}))
            }
            "liveBitrate" => {
                // The stream doctor's trial starts from the encoder's live rate, never the saved one.
                let i = self.client.server_info_https().map_err(HostError::from)?;
                Ok(json!({"runtime":i.capabilities.has(Feature::RuntimeBitrate),"kbps":i.encoder_bitrate_kbps}))
            }
            "quit" => {
                let info=self.client.server_info_https().map_err(HostError::from)?;
                if !quit_allowed(&info) { return Err("The host has not granted permission to quit games.".into()); }
                validate_quit_identity(info.current_game,info.current_game_uuid.as_deref(),&v)?;
                if info.capabilities.has(Feature::NativeApi) {
                    let session=json!(self.client.session().map_err(HostError::from)?);
                    if !matches!(session["owner"].as_str(),Some("you" | "none")) {
                        return Err("The running session belongs to another device.".into());
                    }
                }
                match self.client.cancel() {
                    Ok(true) => (),
                    Ok(false) => return Err("The host declined to quit the game.".into()),
                    Err(nightjar_core::http::Error::Status { code:599,.. }) => return Err("The running game belongs to another device.".into()),
                    Err(error) => return Err(HostError::from(error)),
                }
                let after=self.client.server_info_https().map_err(HostError::from)?;
                if after.current_game != 0 { return Err("A game is still running. Refresh before trying again.".into()); }
                Ok(json!({"quit":true}))
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
                if gamepad_mask > 0xFFFF { return Err("invalid controller mask (maximum sixteen controllers)".into()); }
                let request = LaunchRequest {
                    gamepad_mask: gamepad_mask as u32,
                    app_id,
                    rate_change: true,
                    app_uuid: v["appUUID"].as_str().unwrap_or("").into(),
                    width,
                    height,
                    fps,
                    hdr,
                    clipboard_sync: v["clipboardSync"].as_bool().unwrap_or(false),
                    audio,
                    ri_key: key,
                    ri_key_id: key_id,
                    // The query carries it only for hosts that offer client FEC.
                    fec: v.get("fec").and_then(Value::as_i64).map(|n| crate::fec_choice(n.clamp(-2,255) as i16)),
                    // The engine sends it only to hosts other than Rubylight, which get DisplayCaps.
                    display_luminance: v["displayHeadroom"].as_f64().and_then(|h| crate::display::luminance(h as f32)),
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
                    "runtimeBitrate":i.capabilities.has(Feature::RuntimeBitrate),
                    // As Nightjar's desktop client: only a Rubylight host is told the route is wireless.
                    "clientWireless":v["clientWireless"].as_bool().unwrap_or(false)
                        && i.capabilities.family() == nightjar_core::http::Family::Rubylight,
                    "clipboardRead":clipboard_permissions(&i).0,"clipboardWrite":clipboard_permissions(&i).1}),
                )
            }
            _ => Err("unknown host operation".into()),
        }
    }
}
fn quit_allowed(info: &nightjar_core::http::ServerInfo) -> bool {
    use nightjar_core::http::PERMISSION_LAUNCH;
    info.capabilities.evidence().is_none_or(|e| e.permission == -1 || (e.permission.max(0) as u32 & PERMISSION_LAUNCH) != 0)
}
fn validate_quit_identity(current: i32, uuid: Option<&str>, request: &Value) -> Result<(),HostError> {
    if current <= 0 || request["expectedAppID"].as_i64() != Some(i64::from(current))
        || uuid.unwrap_or("") != request["expectedAppUUID"].as_str().unwrap_or("") {
        return Err("The running game changed. Refresh and confirm again.".into());
    }
    Ok(())
}

fn validate_radeon_write(panel: &Value, request: &Value, restore: bool) -> Result<(), HostError> {
    if panel["host_control"] != true || panel["writable_now"] != true || panel["state"] != "configurable" {
        return Err("Graphics changes require Host control and an owned session.".into());
    }
    if panel["revision"].as_u64().is_none() || panel["revision"] != request["revision"] {
        return Err("Graphics settings changed on the host. Refresh and try again.".into());
    }
    if restore { return Ok(()); }
    let write=&request["write"];
    let gpu=panel["gpus"].as_array().and_then(|g|g.iter().find(|g|g["id"] == write["gpu"])).ok_or("The GPU is no longer available.")?;
    let changes=write["changes"].as_array().filter(|c|c.len() == 1).ok_or("Change one setting at a time.")?;
    let change=&changes[0];
    let setting=gpu["settings"].as_array().and_then(|s|s.iter().find(|s|s["id"] == change["id"])).ok_or("The setting is no longer available.")?;
    let value=&change["value"];
    let valid=setting["state"] == "configurable" && match setting["kind"].as_str() {
        Some("toggle") => setting["value"].is_boolean() && value.is_boolean(),
        Some("choice") => setting["value"].is_string() && value.is_string() && setting["options"].as_array().is_some_and(|o|o.iter().any(|o|o["value"] == *value)),
        Some("integer") => match (setting["value"].as_i64(),value.as_i64(),setting["range"]["min"].as_i64(),setting["range"]["max"].as_i64(),setting["range"]["step"].as_i64()) {
            (Some(_),Some(n),Some(min),Some(max),Some(step)) if step > 0 && max > min => n >= min && n <= max && (i128::from(n)-i128::from(min)) % i128::from(step) == 0,
            _ => false,
        },
        _ => false,
    };
    if !valid { return Err("This setting is unavailable or the requested value is outside its supported range.".into()); }
    Ok(())
}

// Recheck ownership, app identity and permission immediately before a host write.
fn validate_session_action(current: &Value, request: &Value) -> Result<(), HostError> {
    if current["app"]["app_id"] != request["expectedAppID"] || current["owner"] != request["expectedOwner"] {
        return Err("The host session changed. Refresh it before trying again.".into());
    }
    let allowed=current["actions"].as_array().is_some_and(|actions| actions.iter().any(|a|
        a["id"] == request["action"] && a["allowed"].as_bool() == Some(true)));
    if !allowed { return Err("The host does not allow this session action right now.".into()); }
    Ok(())
}
fn clipboard_permissions(i: &nightjar_core::http::ServerInfo) -> (bool,bool) {
    use nightjar_core::http::{PERMISSION_CLIPBOARD_READ,PERMISSION_CLIPBOARD_SET};
    if !i.capabilities.has(Feature::Clipboard) { return (false,false); }
    let permission=i.capabilities.evidence().map_or(0,|e|e.permission.max(0) as u32);
    (permission & PERMISSION_CLIPBOARD_READ != 0,permission & PERMISSION_CLIPBOARD_SET != 0)
}
fn host_info_value(i: &nightjar_core::http::ServerInfo, has_local_pin: bool) -> Value {
    // Another address can recognize our identity without having a local certificate pin.
    // Offer PIN pairing for that endpoint instead of attempting unpinned HTTPS.
    json!({"name":i.hostname,"uniqueID":i.unique_id,"paired":i.paired && has_local_pin,
        "appVersion":i.app_version,"codecSupport":i.server_codec_mode_support,"currentGame":i.current_game,"currentGameUUID":i.current_game_uuid,"quitAllowed":has_local_pin && quit_allowed(i),
        "clipboardRead":has_local_pin && clipboard_permissions(i).0,"clipboardWrite":has_local_pin && clipboard_permissions(i).1})
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
    fn hosts_see_the_engine_release_and_mystic() {
        let version = app_version();
        assert_eq!(version, format!("4.0.1+mystic.{}", env!("CARGO_PKG_VERSION")));
        // The engine keeps printable ASCII only; nothing of the version may be dropped.
        assert!(version.chars().all(|c| c.is_ascii_graphic()));
    }
    #[test]
    fn quit_permission_uses_launch_grant_and_allows_legacy_hosts() {
        use nightjar_core::http::{PERMISSION_LAUNCH,PERMISSION_VIEW};
        for (permission,expected) in [(-1,true),(0,false),(PERMISSION_VIEW as i64,false),(PERMISSION_LAUNCH as i64,true)] {
            let field=if permission == -1 { String::new() } else { format!("<Permission>{permission}</Permission>") };
            let xml=format!(r#"<root status_code="200"><hostname>PC</hostname><uniqueid>h</uniqueid><PairStatus>1</PairStatus>{field}<state>SUNSHINE_SERVER_FREE</state></root>"#);
            let info=nightjar_core::http::ServerInfo::parse(&xml,47989).unwrap();
            assert_eq!(quit_allowed(&info),expected,"permission {permission}, evidence {:?}",info.capabilities.evidence());
        }
    }
    #[test]
    fn quit_requires_the_confirmed_running_id_and_uuid() {
        let request=json!({"expectedAppID":12,"expectedAppUUID":"game-a"});
        assert!(validate_quit_identity(12,Some("game-a"),&request).is_ok());
        assert!(validate_quit_identity(13,Some("game-a"),&request).is_err());
        assert!(validate_quit_identity(12,Some("game-b"),&request).is_err());
        assert!(validate_quit_identity(0,None,&request).is_err());
        assert!(validate_quit_identity(12,None,&request).is_err());
        assert!(validate_quit_identity(12,None,&json!({"expectedAppID":12,"expectedAppUUID":""})).is_ok());
    }
    #[test]
    fn graphics_writes_validate_permissions_revision_type_range_and_choices() {
        let mut panel=json!({"revision":7,"state":"configurable","host_control":true,"writable_now":true,"gpus":[{"id":1,"settings":[
            {"id":"toggle","kind":"toggle","state":"configurable","value":false},
            {"id":"number","kind":"integer","state":"configurable","value":30,"range":{"min":30,"max":120,"step":5}},
            {"id":"choice","kind":"choice","state":"configurable","value":"off","options":[{"value":"on"},{"value":"off"}]},
            {"id":"locked","kind":"toggle","state":"read_only","value":false}]}]});
        let request=|id: &str,value: Value| json!({"revision":7,"write":{"gpu":1,"changes":[{"id":id,"value":value}]}});
        for (id,value) in [("toggle",json!(true)),("number",json!(45)),("choice",json!("on"))] {
            assert!(validate_radeon_write(&panel,&request(id,value),false).is_ok());
        }
        for (id,value) in [("toggle",json!(1)),("number",json!(44)),("number",json!(125)),("choice",json!("unknown")),("locked",json!(true)),("missing",json!(true))] {
            assert!(validate_radeon_write(&panel,&request(id,value),false).is_err());
        }
        assert!(validate_radeon_write(&panel,&json!({"revision":6}),true).is_err());
        assert!(validate_radeon_write(&panel,&json!({"revision":7}),true).is_ok());
        panel["host_control"]=json!(false);
        assert!(validate_radeon_write(&panel,&request("toggle",json!(true)),false).is_err());
        assert!(validate_radeon_write(&panel,&json!({"revision":7}),true).is_err());
    }
    #[test]
    fn session_actions_reject_changed_owner_app_and_missing_permissions() {
        let current=json!({"app":{"app_id":12},"owner":"you","actions":[{"id":"end","allowed":true},{"id":"close_game","allowed":false}]});
        let valid=json!({"action":"end","expectedAppID":12,"expectedOwner":"you"});
        assert!(validate_session_action(&current,&valid).is_ok());
        for altered in [json!({"action":"end","expectedAppID":13,"expectedOwner":"you"}),
            json!({"action":"end","expectedAppID":12,"expectedOwner":"other"}),
            json!({"action":"close_game","expectedAppID":12,"expectedOwner":"you"}),
            json!({"action":"unknown","expectedAppID":12,"expectedOwner":"you"})] {
            assert!(validate_session_action(&current,&altered).is_err());
        }
    }
    #[test]
    fn only_transport_errors_allow_a_recovery_retry() {
        assert!(HostError::from(nightjar_core::http::Error::Io(std::io::ErrorKind::TimedOut.into())).retryable);
        assert!(!HostError::from(nightjar_core::http::Error::CertificateMismatch).retryable);
        assert!(!HostError::from(nightjar_core::http::Error::NotPaired).retryable);
        assert!(!HostError::from(nightjar_core::http::Error::Status { code: 401, message: "denied".into() }).retryable);
    }
    #[test]
    fn clipboard_permissions_are_directional_and_need_a_local_pin_for_the_ui() {
        use nightjar_core::http::{PERMISSION_VIEW,PERMISSION_CLIPBOARD_READ,PERMISSION_CLIPBOARD_SET};
        for (permissions,expected) in [(PERMISSION_VIEW,(false,false)),
            (PERMISSION_VIEW | PERMISSION_CLIPBOARD_READ,(true,false)),
            (PERMISSION_VIEW | PERMISSION_CLIPBOARD_SET,(false,true)),
            (PERMISSION_VIEW | PERMISSION_CLIPBOARD_READ | PERMISSION_CLIPBOARD_SET,(true,true))] {
            let xml=format!(r#"<root status_code="200"><hostname>PC</hostname><uniqueid>host1</uniqueid><PairStatus>1</PairStatus><Permission>{permissions}</Permission><state>SUNSHINE_SERVER_FREE</state></root>"#);
            let info=nightjar_core::http::ServerInfo::parse(&xml,47989).unwrap();
            assert_eq!(clipboard_permissions(&info),expected);
            assert_eq!(host_info_value(&info,false)["clipboardRead"],false);
            assert_eq!(host_info_value(&info,false)["clipboardWrite"],false);
        }
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
