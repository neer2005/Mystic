//! Additive host-control bridge: protocol and certificate verification remain in Nightjar.
use rubylight_protocol::pairing_uri::PairingUri;
use nightjar_core::http::{Availability, Feature, AppControl, ClientIdentity, HostClient, HostDisplay, LaunchRequest, PairResult, Reason};
use rand_core::{OsRng, RngCore};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::sync::Arc;

/// Nightjar's release at the pinned revision (Cargo.toml). Hosts see the engine they talk to;
/// the suffix says it runs inside Mystic.
const NIGHTJAR_RELEASE: &str = "4.3.1";
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
    pub(crate) client: Arc<HostClient>,
    /// The capabilities of the last launch's serverinfo, so the overlay's hardware poll does not
    /// ask for serverinfo every time.
    capabilities: std::sync::Mutex<Option<nightjar_core::http::HostCapabilities>>,
    address: String,
    http_port: u16,
}
/// For the Files page, whose answers come from the same envelope.
pub(crate) fn envelope_for(result: Result<Value, String>) -> *mut c_char { envelope(result) }
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
        Ok(MysticHost { client: Arc::new(client), capabilities: std::sync::Mutex::new(None), address: text(address)?.to_owned(), http_port: port })
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
/// Puts a PNG on the PC's clipboard, `{"sent":true}` or the reason it could not.
#[no_mangle]
pub unsafe extern "C" fn mystic_host_clipboard_image_send(host: *const MysticHost, png: *const u8, length: usize) -> *mut c_char {
    host_envelope((|| {
        let host = host.as_ref().ok_or("null host")?;
        if png.is_null() { return Err("null image".into()); }
        let png = std::slice::from_raw_parts(png, length);
        host.client.send_clipboard_image(png).map_err(|e| image_error(e, true))?;
        Ok(json!({"sent":true}))
    })())
}
/// The PNG on the PC's clipboard: `{"image":true}` with the bytes in `png`, freed with
/// `mystic_bytes_free`; `{"image":false}` while it holds no image.
#[no_mangle]
pub unsafe extern "C" fn mystic_host_clipboard_image_read(host: *const MysticHost, png: *mut *mut u8, length: *mut usize) -> *mut c_char {
    host_envelope((|| {
        let host = host.as_ref().ok_or("null host")?;
        if png.is_null() || length.is_null() { return Err("null output".into()); }
        *png = std::ptr::null_mut();
        *length = 0;
        let Some(image) = host.client.clipboard_image().map_err(|e| image_error(e, false))? else {
            return Ok(json!({"image":false}));
        };
        let image = image.into_boxed_slice();
        *length = image.len();
        *png = Box::into_raw(image).cast();
        Ok(json!({"image":true}))
    })())
}
#[no_mangle]
pub unsafe extern "C" fn mystic_bytes_free(bytes: *mut u8, length: usize) {
    if !bytes.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, length)));
    }
}
/// Nightjar's wording for each refusal; the host's own errors keep their retry advice.
fn image_error(error: nightjar_core::http::ImageClipboardError, send: bool) -> HostError {
    use nightjar_core::http::ImageClipboardError as E;
    match error {
        E::TooLarge(why) => format!("The image is too large for the PC's clipboard: {why}").into(),
        E::NotPng(why) if send => format!("The image on the Mac's clipboard is no valid PNG: {why}").into(),
        E::NotPng(why) => format!("The PC sent no valid PNG image: {why}").into(),
        E::Unsupported if send => "The PC could not read this image.".into(),
        E::Unsupported => "The PC could not convert the image on its clipboard.".into(),
        E::Forbidden => "The PC refused its image clipboard to this device. Check the device's clipboard permissions on the PC; images move only during a stream of this device.".into(),
        E::Host(e) => HostError::from(e),
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
    /// Whether the PC offers its image clipboard to this device, which only its native API says.
    /// A failed read offers nothing, as on Nightjar.
    fn image_clipboard(&self, info: &nightjar_core::http::ServerInfo) -> bool {
        info.capabilities.has(Feature::NativeApi)
            && self.client.native_capabilities_with_files()
                .is_ok_and(|native| info.capabilities.clone().with_native(&native).has(Feature::ImageClipboard))
    }
    fn request(&self, operation: &str, v: Value) -> Result<Value, HostError> {
        match operation {
            "info" => {
                let i = self.info()?;
                let mut value = host_info_value(&i, self.client.server_certificate_pem().is_some());
                if i.capabilities.has(Feature::WebUi) {
                    value["webUI"] = web_ui_value(web_ui_at(&self.address, self.http_port, i.https_port));
                }
                Ok(value)
            }
            "pair" => {
                let pin = field(&v, "pin")?;
                if pin.len() != 4 || !pin.bytes().all(|b| b.is_ascii_digit()) {
                    return Err("PIN must be four digits".into());
                }
                let i = self.info()?;
                let result = match v["passphrase"].as_str() {
                    Some(passphrase) if passphrase.chars().count() < 4 => return Err("The passphrase needs at least four characters.".into()),
                    Some(passphrase) => self.client.pair_with_passphrase(&i, pin, passphrase),
                    None => self.client.pair(&i, pin),
                };
                paired_value(result, &i.unique_id, v["passphrase"].is_string())
            }
            "pairLink" => {
                let link = PairingUri::parse(field(&v, "link")?.trim()).ok_or(LINK_INVALID)?;
                let i = self.info()?;
                paired_value(self.client.pair_with_link(&i, &link), &i.unique_id, true)
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
            "hostAudio" | "hostAudioSet" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::NativeApi) { return Ok(json!({"switches":[]})); }
                let offered = crate::host_audio::offered(&self.client.native_capabilities().map_err(HostError::from)?);
                if operation == "hostAudioSet" {
                    let write = crate::host_audio::write(&offered, field(&v, "id")?, v["on"].as_bool().ok_or("missing on")?)?;
                    let audio = self.client.write_audio(&write).map_err(HostError::from)?;
                    return Ok(json!({"switches":crate::host_audio::switches(&offered, &audio)}));
                }
                if offered.is_empty() { return Ok(json!({"switches":[]})); }
                let audio = self.client.audio().map_err(HostError::from)?;
                Ok(json!({"switches":crate::host_audio::switches(&offered, &audio)}))
            }
            "bitrate" => {
                let i = self.client.server_info_https().map_err(HostError::from)?;
                if !i.capabilities.has(Feature::RuntimeBitrate) { return Err("This host does not support live bitrate changes.".into()); }
                let kbps = v["kbps"].as_u64().filter(|v| (1..=150_000).contains(v)).ok_or("invalid bitrate")? as u32;
                let applied = self.client.set_bitrate(kbps).map_err(HostError::from)?;
                Ok(json!({"kbps":applied}))
            }
            // A Foundation Sunshine host runs the bitrate controller itself (`host_abr.rs` in
            // Nightjar's desktop client); others answer 404, which is "none".
            "hostBitrateStart" => {
                use nightjar_core::http::foundation::AbrRequest;
                let max = v["maxKbps"].as_u64().filter(|v| (1..=150_000).contains(v)).ok_or("invalid bitrate")? as u32;
                match self.client.abr_capabilities() {
                    Ok(caps) if caps.supported => {}
                    Ok(_) | Err(nightjar_core::http::Error::NotFound(_)) => return Ok(json!({"on":false})),
                    Err(error) => return Err(HostError::from(error)),
                }
                let on = self.client.configure_abr(&AbrRequest::balanced_up_to(max)).map_err(HostError::from)?;
                Ok(json!({"on":true,"initialKbps":on.initial_bitrate,"maxKbps":on.max_bitrate}))
            }
            "hostBitrateStop" => {
                self.client.configure_abr(&nightjar_core::http::foundation::AbrRequest::off()).map_err(HostError::from)?;
                Ok(json!({"on":false}))
            }
            "hostBitrateFeedback" => {
                let action = self.client.abr_feedback(&abr_feedback(&v)?).map_err(HostError::from)?;
                Ok(json!({"newKbps":action.new_bitrate.filter(|kbps| *kbps > 0),"reason":action.reason}))
            }
            // The overlay's host readings: {"available":false} where the host offers none, so the
            // poll stops (Nightjar's `hardware_answer`); an error is a failed request.
            "hardwareMetrics" => {
                use nightjar_core::http::{Error, HostApiError};
                let cached = self.capabilities.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let capabilities = match cached {
                    Some(c) => c,
                    None => self.client.server_info_https().map_err(HostError::from)?.capabilities,
                };
                match self.client.hardware_metrics(&capabilities) {
                    Ok(m) => Ok(crate::diagnostics::hardware_value(&m)),
                    Err(HostApiError::Unavailable { .. } | HostApiError::UnsupportedVersion)
                    | Err(HostApiError::Host(Error::NotFound(_) | Error::Status { code: 403 | 404 | 409, .. } | Error::Api { status: 403 | 404 | 409, .. })) => {
                        Ok(json!({"available":false}))
                    }
                    Err(HostApiError::Host(error)) => Err(HostError::from(error)),
                }
            }
            // Android's remote access check: five pinned serverinfo probes, then the route.
            "remoteCheck" => {
                let id = v["uniqueID"].as_str().unwrap_or("");
                Ok(crate::diagnostics::remote_value(self.client.remote_check(id)))
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
                let fps = dimension(&v, "fps", 500)?;
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
                    ten_bit_sdr: !hdr && v["tenBitSDR"].as_bool().unwrap_or(false),
                    clipboard_sync: v["clipboardSync"].as_bool().unwrap_or(false),
                    play_local_audio: v["playLocalAudio"].as_bool().unwrap_or(false),
                    virtual_display: v["virtualDisplay"].as_bool().unwrap_or(false),
                    host_display: host_display(&v)?,
                    virtual_display_scale: render_scale(&v),
                    virtual_display_dpi: display_scale(&v),
                    audio,
                    ri_key: key,
                    ri_key_id: key_id,
                    // The query carries it only for hosts that offer client FEC.
                    fec: v.get("fec").and_then(Value::as_i64).map(|n| crate::fec_choice(n.clamp(-2,255) as i16)),
                    // The engine sends it only to hosts other than Rubylight, which get DisplayCaps.
                    display_luminance: v["displayHeadroom"].as_f64().and_then(|h| crate::display::luminance(h as f32)),
                    // Hosts that read fractions launch 59.94 Hz when it rounds to the stream's rate.
                    client_refresh_rate_x100: refresh_x100(&v),
                    ..Default::default()
                };
                *self.capabilities.lock().unwrap_or_else(|e| e.into_inner()) = Some(i.capabilities.clone());
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
                    // The stream's DESCRIBE must offer 0x5540 as well; the session checks that.
                    "cursorShapes":i.capabilities.has(Feature::CursorShape),
                    "keyboardLayout":i.capabilities.has(Feature::ClientKeyboardLayout),
                    "textFields":i.capabilities.has(Feature::TextInput),
                    // As Nightjar's desktop client: only a Rubylight host is told the route is wireless.
                    "clientWireless":v["clientWireless"].as_bool().unwrap_or(false)
                        && i.capabilities.family() == nightjar_core::http::Family::Rubylight,
                    "clipboardRead":clipboard_permissions(&i).0,"clipboardWrite":clipboard_permissions(&i).1,
                    "imageClipboard":self.image_clipboard(&i)}),
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
const LINK_INVALID: &str = "That pairing link is not valid. Show a new QR code on the PC and copy its link again.";
/// What a pairing attempt comes to. A one-time PIN or link is spent, so it asks for a new one.
fn paired_value(result: Result<PairResult, nightjar_core::http::Error>, unique_id: &str, one_time: bool) -> Result<Value, HostError> {
    match result {
        Err(nightjar_core::http::Error::CertificateMismatch) => {
            Err("This PC's certificate does not match the pairing link, so Mystic did not pair. Pair only with a link from your own PC.".into())
        }
        Err(error) => Err(error.into()),
        Ok(PairResult::Paired { server_certificate_pem }) => Ok(json!({"certificate":server_certificate_pem,"uniqueID":unique_id})),
        Ok(PairResult::PinWrong) if one_time => Err("PIN rejected. Generate a new one-time PIN in your host's web UI and check the passphrase.".into()),
        Ok(PairResult::PinWrong) => Err("The PIN entered on the host did not match.".into()),
        Ok(PairResult::AlreadyInProgress) => Err("Another device is pairing. Try again when it finishes.".into()),
        Ok(PairResult::Failed(_)) if one_time => Err("The host declined. Generate a new one-time PIN or pairing link on the PC, then retry.".into()),
        Ok(PairResult::Failed(reason)) => Err(format!("Pairing failed: {reason:?}").into()),
    }
}
/// Where a pairing link points and what it names, without its secrets. IPv6 addresses lose
/// their brackets, as typed ones do.
fn pairing_link_value(text: &str) -> Result<Value, String> {
    let link = PairingUri::parse(text.trim()).ok_or(LINK_INVALID)?;
    let host = link.host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(&link.host);
    Ok(json!({"host":host,"port":link.port,"name":link.name,"uniqueID":link.unique_id}))
}
#[no_mangle]
pub unsafe extern "C" fn mystic_pairing_link_parse(link: *const c_char) -> *mut c_char {
    if link.is_null() { return envelope(Err(LINK_INVALID.into())); }
    envelope(text(link).map_err(|_| LINK_INVALID.to_owned()).and_then(pairing_link_value))
}
/// The host software as Nightjar's `software_label` names it.
fn software_label(capabilities: &nightjar_core::http::HostCapabilities) -> String {
    use nightjar_core::http::Family;
    match capabilities.family() {
        Family::Rubylight => format!("Rubylight {}", capabilities.host_version().unwrap_or_default()).trim_end().to_owned(),
        Family::Vibepollo => "Vibepollo-compatible host".into(),
        Family::Apollo => "Apollo-compatible host".into(),
        Family::Sunshine => "Sunshine-compatible host".into(),
        Family::GameStream => "NVIDIA GameStream".into(),
        Family::Unknown => "Moonlight-compatible host".into(),
    }
}
/// What the host lets this device do, by name; nil when it reports no permissions.
fn permission_names(permission: i64) -> Option<Vec<&'static str>> {
    use nightjar_core::http::{PERMISSION_CLIPBOARD_READ, PERMISSION_CLIPBOARD_SET, PERMISSION_INPUT, PERMISSION_LAUNCH, PERMISSION_LIST, PERMISSION_SERVER_COMMAND, PERMISSION_VIEW};
    if permission == -1 { return None; }
    let bits = permission.max(0) as u32;
    Some([(PERMISSION_LIST, "List applications"), (PERMISSION_VIEW, "View streams"), (PERMISSION_LAUNCH, "Launch and quit applications"),
        (PERMISSION_INPUT, "Send input"), (PERMISSION_CLIPBOARD_SET, "Send clipboard"), (PERMISSION_CLIPBOARD_READ, "Read clipboard"),
        (PERMISSION_SERVER_COMMAND, "Run server commands")]
        .into_iter().filter(|(bit, _)| bits & bit != 0).map(|(_, name)| name).collect())
}
fn web_ui_value(place: Option<Result<String, String>>) -> Value {
    match place {
        Some(Ok(url)) => json!({"url":url}),
        Some(Err(problem)) => json!({"problem":problem}),
        None => Value::Null,
    }
}
/// Nightjar's rule: the HTTPS port + 6 (47990 by default), else the HTTP port + 1.
fn web_ui_at(address: &str, http_port: u16, https_port: u16) -> Option<Result<String, String>> {
    let port = if https_port != 0 { https_port.checked_add(6)? } else { http_port.checked_add(1)? };
    Some(url_host(address).map(|host| format!("https://{host}:{port}")))
}
/// The saved address as a URL's host: an IP address or a host name, nothing else.
fn url_host(address: &str) -> Result<String, String> {
    use std::net::{Ipv4Addr, Ipv6Addr};
    let (bare, bracketed) = match address.strip_prefix('[').and_then(|a| a.strip_suffix(']')) {
        Some(inner) => (inner, true),
        None => (address, false),
    };
    if bare.split_once('%').is_some_and(|(ip, _)| ip.parse::<Ipv6Addr>().is_ok()) {
        return Err(format!("Browsers cannot open an address with a zone ID ({address}). Open the web UI from another address of this PC."));
    }
    if let Ok(ip) = bare.parse::<Ipv6Addr>() {
        return Ok(ip.to_ipv4_mapped().map_or_else(|| format!("[{ip}]"), |v4| v4.to_string()));
    }
    if !bracketed {
        if let Ok(ip) = bare.parse::<Ipv4Addr>() { return Ok(ip.to_string()); }
        if is_host_name(bare) { return Ok(bare.to_owned()); }
    }
    Err(format!("The saved address {address} is not an IP address or host name, so it makes no web UI link."))
}
/// ASCII labels of letters, digits, '-' and '_'; a last label of digits alone reads as broken IPv4.
fn is_host_name(name: &str) -> bool {
    let name = name.strip_suffix('.').unwrap_or(name);
    let label = |l: &str| (1..=63).contains(&l.len()) && !l.starts_with('-') && !l.ends_with('-')
        && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    name.len() <= 253 && name.split('.').all(label)
        && !name.rsplit('.').next().is_some_and(|last| last.bytes().all(|b| b.is_ascii_digit()))
}
/// The launch's display arrangement; an unknown one is refused rather than ignored.
fn host_display(v: &Value) -> Result<HostDisplay, String> {
    Ok(match v["hostDisplay"].as_str().unwrap_or("default") {
        "default" => HostDisplay::HostDefault,
        "exclusive" => HostDisplay::Exclusive,
        "extended_primary" => HostDisplay::ExtendedPrimary,
        "extended" => HostDisplay::Extended,
        "extended_isolated" => HostDisplay::ExtendedIsolated,
        "extended_primary_isolated" => HostDisplay::ExtendedPrimaryIsolated,
        "physical" => HostDisplay::Physical,
        _ => return Err("invalid display arrangement".into()),
    })
}
/// Nightjar's `RENDER_SCALE`.
fn render_scale(v: &Value) -> u32 {
    v["renderScalePercent"].as_u64().unwrap_or(100).clamp(50, 200) as u32
}
/// Nightjar's `DISPLAY_SCALES`: a scale Windows does not offer keeps the PC's own, since the PC
/// would refuse the launch.
fn display_scale(v: &Value) -> u32 {
    const SCALES: [u64; 12] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];
    v["displayScalePercent"].as_u64().filter(|n| SCALES.contains(n)).unwrap_or(0) as u32
}
fn availability_name(availability: Availability) -> &'static str {
    match availability {
        Availability::Supported => "supported",
        Availability::Unknown => "unknown",
        Availability::Unsupported(Some(Reason::UpdateHost)) => "update",
        Availability::Unsupported(Some(Reason::VirtualDisplayOff)) => "off",
        Availability::Unsupported(Some(Reason::VirtualDisplayDriver)) => "driver",
        Availability::Unsupported(_) => "never",
    }
}
fn host_info_value(i: &nightjar_core::http::ServerInfo, has_local_pin: bool) -> Value {
    // Another address can recognize our identity without having a local certificate pin.
    // Offer PIN pairing for that endpoint instead of attempting unpinned HTTPS.
    json!({"name":i.hostname,"uniqueID":i.unique_id,"paired":i.paired && has_local_pin,
        "appVersion":i.app_version,"codecSupport":i.server_codec_mode_support,"currentGame":i.current_game,"currentGameUUID":i.current_game_uuid,"quitAllowed":has_local_pin && quit_allowed(i),
        "clipboardRead":has_local_pin && clipboard_permissions(i).0,"clipboardWrite":has_local_pin && clipboard_permissions(i).1,
        "software":software_label(&i.capabilities),"nativeAPI":has_local_pin && i.capabilities.has(Feature::NativeApi),
        "permissions":i.capabilities.evidence().filter(|_| has_local_pin).and_then(|e| permission_names(i64::from(e.permission))),
        "otpPairing":availability_name(i.capabilities.availability(Feature::OtpPairing)),
        "display":{"virtualDisplay":availability_name(i.capabilities.availability(Feature::VirtualDisplay)),
            "modes":availability_name(i.capabilities.availability(Feature::HostDisplayModes)),
            "scale":availability_name(i.capabilities.availability(Feature::DisplayScale))}})
}
fn dimension(v: &Value, name: &str, max: u32) -> Result<u32, String> {
    v[name]
        .as_u64()
        .filter(|n| *n > 0 && *n <= u64::from(max))
        .map(|n| n as u32)
        .ok_or_else(|| format!("invalid {name}"))
}
/// The app's network report since the last one; figures out of range count as unmeasured.
fn abr_feedback(v: &Value) -> Result<nightjar_core::http::foundation::AbrFeedback, String> {
    let figure = |name: &str, max: f64| v[name].as_f64().filter(|n| n.is_finite() && (0.0..=max).contains(n)).unwrap_or(0.0);
    Ok(nightjar_core::http::foundation::AbrFeedback {
        packet_loss: figure("packetLoss", 100.0),
        rtt_ms: figure("rttMs", 60_000.0),
        decode_fps: figure("decodeFps", 1000.0),
        dropped_frames: v["droppedFrames"].as_u64().map_or(0, |n| n.min(u64::from(u32::MAX)) as u32),
        current_bitrate: v["currentKbps"].as_u64().filter(|n| (1..=150_000).contains(n)).ok_or("invalid bitrate")? as u32,
    })
}
/// The display's refresh rate x100 (5994 for 59.94 Hz); 0 when absent or out of range.
fn refresh_x100(v: &Value) -> u32 {
    v["clientRefreshRateX100"].as_u64().filter(|n| (100..=100_000).contains(n)).map_or(0, |n| n as u32)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hosts_see_the_engine_release_and_mystic() {
        let version = app_version();
        assert_eq!(version, format!("4.3.1+mystic.{}", env!("CARGO_PKG_VERSION")));
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
    fn the_web_ui_follows_nightjars_ports_and_addresses() {
        assert_eq!(web_ui_at("pc", 47989, 47984), Some(Ok("https://pc:47990".into())));
        assert_eq!(web_ui_at("pc", 47989, 0), Some(Ok("https://pc:47990".into())));
        assert_eq!(web_ui_at("pc", 47989, 65533), None, "past the last port");
        let url = |address: &str| web_ui_at(address, 47989, 47984).unwrap();
        assert_eq!(url("100.66.0.33"), Ok("https://100.66.0.33:47990".into()));
        assert_eq!(url("::1"), Ok("https://[::1]:47990".into()));
        assert_eq!(url("::ffff:192.168.1.2"), Ok("https://192.168.1.2:47990".into()));
        assert!(url("fe80::1%en0").unwrap_err().contains("zone ID"));
        for bad in ["a b", "x/y", "pc@evil", "1.2.3", "-pc", "[pc]"] { assert!(url(bad).is_err(), "{bad}"); }
        assert_eq!(web_ui_value(None), Value::Null);
        assert_eq!(web_ui_value(Some(Ok("https://pc:1".into())))["url"], "https://pc:1");
    }
    #[test]
    fn permissions_are_named_and_absent_when_unreported() {
        use nightjar_core::http::{PERMISSION_CLIPBOARD_READ, PERMISSION_CONTROLLER, PERMISSION_VIEW};
        assert_eq!(permission_names(-1), None);
        assert_eq!(permission_names(0), Some(vec![]));
        assert_eq!(permission_names(i64::from(PERMISSION_VIEW | PERMISSION_CONTROLLER | PERMISSION_CLIPBOARD_READ)),
            Some(vec!["View streams", "Send input", "Read clipboard"]));
    }
    #[test]
    fn pairing_links_give_their_place_but_never_their_secrets() {
        let fp = "07".repeat(32);
        let link = format!(" rubylight://pair?v=1&host=%5Bfe80%3A%3A1%5D&port=48123&otp=4821&pass=se%26cret&id=ABC&fp={fp}&name=Den%20PC\n");
        let value = pairing_link_value(&link).unwrap();
        assert_eq!((value["host"].as_str(), value["port"].as_u64(), value["name"].as_str(), value["uniqueID"].as_str()),
            (Some("fe80::1"), Some(48123), Some("Den PC"), Some("ABC")));
        let shown = value.to_string();
        assert!(!shown.contains("4821") && !shown.contains("cret") && !shown.contains(&fp));
        assert_eq!(pairing_link_value("rubylight://pair?v=2").unwrap_err(), LINK_INVALID);
        assert_eq!(pairing_link_value(&link.replace(&fp, "07")).unwrap_err(), LINK_INVALID);
        assert_eq!(pairing_link_value("192.168.1.2").unwrap_err(), LINK_INVALID, "never read as an address");
    }
    #[test]
    fn a_spent_or_forged_link_says_what_to_do() {
        let forged = paired_value(Err(nightjar_core::http::Error::CertificateMismatch), "h", true).err().unwrap();
        assert!(forged.message.contains("does not match"));
        let wrong = paired_value(Ok(PairResult::PinWrong), "h", true).err().unwrap();
        assert!(wrong.message.contains("new one-time PIN"));
        assert!(paired_value(Ok(PairResult::PinWrong), "h", false).err().unwrap().message.contains("on the host"));
        let paired = paired_value(Ok(PairResult::Paired { server_certificate_pem: "cert".into() }), "h", true).ok().unwrap();
        assert_eq!((paired["certificate"].as_str(), paired["uniqueID"].as_str()), (Some("cert"), Some("h")));
    }
    #[test]
    fn display_choices_are_read_within_nightjars_bounds() {
        assert!(matches!(host_display(&json!({})), Ok(HostDisplay::HostDefault)));
        assert!(matches!(host_display(&json!({"hostDisplay":"extended_primary_isolated"})), Ok(HostDisplay::ExtendedPrimaryIsolated)));
        assert!(host_display(&json!({"hostDisplay":"mirror"})).is_err());
        assert_eq!((render_scale(&json!({})), render_scale(&json!({"renderScalePercent":10})), render_scale(&json!({"renderScalePercent":300}))), (100, 50, 200));
        assert_eq!((display_scale(&json!({})), display_scale(&json!({"displayScalePercent":175})), display_scale(&json!({"displayScalePercent":110}))), (0, 175, 0));
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
    #[test]
    fn host_bitrate_reports_keep_figures_in_range() {
        let f = abr_feedback(&json!({"packetLoss":2.5,"rttMs":8,"decodeFps":119.5,"droppedFrames":6,"currentKbps":35000})).unwrap();
        assert_eq!((f.packet_loss, f.rtt_ms, f.decode_fps, f.dropped_frames, f.current_bitrate), (2.5, 8.0, 119.5, 6, 35000));
        let f = abr_feedback(&json!({"packetLoss":140,"rttMs":-1,"droppedFrames":u64::MAX,"currentKbps":1})).unwrap();
        assert_eq!((f.packet_loss, f.rtt_ms, f.decode_fps, f.dropped_frames), (0.0, 0.0, 0.0, u32::MAX));
        assert!(abr_feedback(&json!({"currentKbps":0})).is_err());
    }
    #[test]
    fn refresh_rate_is_passed_through_only_in_range() {
        assert_eq!(refresh_x100(&json!({"clientRefreshRateX100":5994})), 5994);
        assert_eq!(refresh_x100(&json!({})), 0);
        assert_eq!(refresh_x100(&json!({"clientRefreshRateX100":99})), 0);
        assert_eq!(refresh_x100(&json!({"clientRefreshRateX100":100_001})), 0);
        assert_eq!(refresh_x100(&json!({"clientRefreshRateX100":-6000})), 0);
    }
}
