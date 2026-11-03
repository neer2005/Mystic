//! The host's night mode and headphone surround: Nightjar's `menu_extras.rs` without its drawing.
//! The switches come from the PC's native capabilities and state from `/audio`; a change applies
//! to this device's stream from its next audio packet and nothing is saved.
use nightjar_core::http::native_api::audio::{reason, Audio, AudioWrite, HEADPHONE_SURROUND, NIGHT_MODE};
use nightjar_core::http::native_api::capabilities::Capabilities;
use nightjar_core::http::native_api::radeon::{Change, ControlState, Value as Setting};
use serde_json::{json, Value};

/// The switches the PC lists that this device may change: the host wants View or Launch.
pub(crate) fn offered(capabilities: &Capabilities) -> Vec<&'static str> {
    let allowed = capabilities.permissions.view || capabilities.permissions.launch;
    [NIGHT_MODE, HEADPHONE_SURROUND].into_iter().filter(|id| allowed && capabilities.features.iter().any(|f| f == id)).collect()
}
/// The offered switches the PC's answer has, in the PC's state.
pub(crate) fn switches(offered: &[&'static str], audio: &Audio) -> Value {
    Value::Array(offered.iter().filter_map(|&id| {
        let setting = audio.settings.iter().find(|s| s.id == id)?;
        Some(json!({"id":id,"label":if id == NIGHT_MODE { "Night Mode" } else { "Headphone Surround" },
            "on":setting.value == Some(Setting::Bool(true)),"enabled":setting.state == ControlState::Configurable,
            "note":match setting.reason.as_deref() {
                None => None,
                Some(reason::NEXT_STREAM) => Some("Applies next stream".to_owned()),
                Some(_) => setting.message.clone(),
            }}))
    }).collect())
}
/// The request that turns one offered switch on or off.
pub(crate) fn write(offered: &[&'static str], id: &str, on: bool) -> Result<AudioWrite, String> {
    if !offered.contains(&id) { return Err("The PC does not offer this audio setting.".into()); }
    Ok(AudioWrite { changes: vec![Change { id: id.into(), value: Setting::Bool(on) }] })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn audio() -> Audio {
        serde_json::from_value(json!({"revision":1,"settings":[
            { "id": "audio.night_mode", "group": "sound", "kind": "toggle", "state": "configurable", "value": true },
            { "id": "audio.headphone_surround", "group": "sound", "kind": "toggle", "state": "configurable", "value": false,
              "reason": "next_stream", "message": "Headphone surround applies from the next stream." }
        ]})).unwrap()
    }
    #[test]
    fn switches_show_the_pcs_state_and_when_a_change_applies() {
        let shown = switches(&[NIGHT_MODE, HEADPHONE_SURROUND], &audio());
        assert_eq!(shown[0]["on"], true);
        assert!(shown[0]["note"].is_null());
        assert_eq!((shown[1]["on"].as_bool(), shown[1]["note"].as_str()), (Some(false), Some("Applies next stream")));
    }
    #[test]
    fn only_what_is_offered_is_shown_or_changed() {
        assert_eq!(switches(&[NIGHT_MODE], &audio()).as_array().unwrap().len(), 1);
        assert!(write(&[NIGHT_MODE], HEADPHONE_SURROUND, true).is_err());
        assert_eq!(write(&[NIGHT_MODE], NIGHT_MODE, true).unwrap().changes[0].id, NIGHT_MODE);
    }
}
