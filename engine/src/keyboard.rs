//! The keyboard layout report (0x553E) and host text field notices (0x553B), as Nightjar's
//! desktop client sends and reads them (`stream/text_field.rs`). The host switches the PC's
//! input language to the reported layout; its notices say when a text field has focus, so text
//! that came without a key (the Mac's emoji picker, dictation) can go to it as UTF-8.
use crate::{with_input, MysticSession, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED, MYSTIC_ERR_UNIMPLEMENTED};
use nightjar_core::control::{ClientMessage, ControlEvent};
use rubylight_protocol::keyboard_layout::{KeyboardLayout, LayoutSource};
use rubylight_protocol::text_input::{is_newer, InputType, NoticeKind, TextInputRequest};
use std::ffi::{c_char, CStr};

/// `MysticTextField::input_type`, in the protocol's order.
pub const MYSTIC_TEXT_FIELD_NONE: u8 = 0xFF;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MysticTextField {
    /// The focused field's type (0 text, 1 number, 2 decimal, 3 phone, 4 email, 5 URL,
    /// 6 password, 7 search, 8 multiline), or MYSTIC_TEXT_FIELD_NONE when none has focus.
    pub input_type: u8,
    /// Never any text for this field (a password, or one the host marks so).
    pub sensitive: bool,
    /// The host sends notices for this stream.
    pub notices: bool,
}
impl Default for MysticTextField {
    fn default() -> Self { Self { input_type: MYSTIC_TEXT_FIELD_NONE, sensitive: false, notices: false } }
}

#[derive(Default)]
pub(crate) struct TextFields {
    field: MysticTextField,
    serial: Option<u32>,
}
impl TextFields {
    pub fn receive(&mut self, event: ControlEvent) {
        let ControlEvent::TextInput(notice) = event else { return };
        // The newest notice wins; one that arrives late is dropped.
        if self.serial.is_some_and(|last| !is_newer(notice.serial, last)) {
            return;
        }
        self.serial = Some(notice.serial);
        self.field = match notice.kind {
            NoticeKind::Lower => MysticTextField { notices: self.field.notices, ..Default::default() },
            NoticeKind::Raise | NoticeKind::Update => MysticTextField {
                input_type: input_type(notice.input_type),
                sensitive: notice.sensitive || notice.input_type == InputType::Password,
                notices: self.field.notices,
            },
        };
    }
}

fn input_type(kind: InputType) -> u8 {
    match kind {
        InputType::Text => 0,
        InputType::Number => 1,
        InputType::Decimal => 2,
        InputType::Phone => 3,
        InputType::Email => 4,
        InputType::Url => 5,
        InputType::Password => 6,
        InputType::Search => 7,
        InputType::Multiline => 8,
    }
}

/// The layout a report names, or None for a source past 3 or a tag the wire cannot carry.
fn layout(source: u8, klid: u32, tag: &str) -> Option<KeyboardLayout> {
    let source = match source {
        0 => LayoutSource::Unknown,
        1 => LayoutSource::Klid,
        2 => LayoutSource::Bcp47,
        3 => LayoutSource::Xkb,
        _ => return None,
    };
    let layout = KeyboardLayout { source, klid, tag: tag.to_owned() };
    layout.encode().map(|_| layout)
}

/// Reports the keyboard layout. `source` 0 unknown, 1 a Windows layout (`klid`), 2 a BCP-47
/// tag, 3 an XKB layout; `tag` at most 64 printable ASCII bytes. MYSTIC_ERR_UNIMPLEMENTED
/// when the host does not take reports.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_keyboard_layout(handle: *const MysticSession, source: u8, klid: u32, tag: *const c_char) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    if tag.is_null() { return MYSTIC_ERR_INVALID_ARGUMENT; }
    let Some(layout) = CStr::from_ptr(tag).to_str().ok().and_then(|tag| layout(source, klid, tag)) else {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    let Some(session) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    match session.send(ClientMessage::KeyboardLayout(layout)) {
        Ok(()) => 0,
        Err(_) => MYSTIC_ERR_UNIMPLEMENTED,
    }
}

/// Asks for text field notices: raises and lowers only, never the text around the cursor.
/// MYSTIC_ERR_UNIMPLEMENTED when the host does not send them.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_text_fields(handle: *const MysticSession) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let Some(session) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    let request = TextInputRequest { notices: true, surrounding_text: false, element_ids: false, max_text: 0 };
    let mut fields = handle.text_fields.lock().unwrap_or_else(|e| e.into_inner());
    match session.send(ClientMessage::TextInputRequest(request)) {
        Ok(()) => {
            fields.field.notices = true;
            0
        }
        Err(_) => MYSTIC_ERR_UNIMPLEMENTED,
    }
}

/// The host's focused text field, as its newest notice describes it.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_text_field(handle: *const MysticSession, out: *mut MysticTextField) -> i32 {
    let (Some(handle), Some(out)) = (handle.as_ref(), out.as_mut()) else { return MYSTIC_ERR_INVALID_ARGUMENT };
    *out = handle.text_fields.lock().unwrap_or_else(|e| e.into_inner()).field;
    0
}

/// Text that came without a key, as UTF-8 text input.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_text(handle: *mut MysticSession, utf8: *const c_char) -> i32 {
    if utf8.is_null() { return MYSTIC_ERR_INVALID_ARGUMENT; }
    let Ok(text) = CStr::from_ptr(utf8).to_str() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    if text.is_empty() || text.chars().any(char::is_control) { return MYSTIC_ERR_INVALID_ARGUMENT; }
    with_input(handle, |q| q.send_text(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rubylight_protocol::text_input::{TextInputNotice, SELECTION_UNKNOWN};

    fn notice(kind: NoticeKind, input_type: InputType, serial: u32) -> ControlEvent {
        ControlEvent::TextInput(TextInputNotice {
            kind, input_type, sensitive: false, no_autocorrect: false, no_autocapitalize: false, enter_action: false,
            serial, selection_start: SELECTION_UNKNOWN, selection_end: SELECTION_UNKNOWN, text: String::new(), element: 0,
        })
    }

    #[test]
    fn the_newest_notice_names_the_field() {
        let mut fields = TextFields::default();
        assert_eq!(fields.field.input_type, MYSTIC_TEXT_FIELD_NONE);
        fields.field.notices = true;
        fields.receive(notice(NoticeKind::Raise, InputType::Email, 5));
        assert_eq!(fields.field, MysticTextField { input_type: 4, sensitive: false, notices: true });
        fields.receive(notice(NoticeKind::Lower, InputType::Text, 4));
        assert_eq!(fields.field.input_type, 4, "an older notice is dropped");
        fields.receive(notice(NoticeKind::Update, InputType::Password, 6));
        assert_eq!(fields.field, MysticTextField { input_type: 6, sensitive: true, notices: true });
        fields.receive(notice(NoticeKind::Lower, InputType::Text, 7));
        assert_eq!(fields.field, MysticTextField { notices: true, ..Default::default() });
        fields.receive(notice(NoticeKind::Raise, InputType::Multiline, 2));
        assert_eq!(fields.field.input_type, MYSTIC_TEXT_FIELD_NONE, "serial 2 is older than 7");
        fields.receive(notice(NoticeKind::Raise, InputType::Multiline, 7u32.wrapping_add(u32::MAX / 2)));
        assert_eq!(fields.field.input_type, 8, "serials wrap");
    }

    #[test]
    fn layouts_are_checked_before_they_go() {
        assert_eq!(layout(1, 0x0407, "00000407"), Some(KeyboardLayout { source: LayoutSource::Klid, klid: 0x0407, tag: "00000407".into() }));
        assert_eq!(layout(2, 0, "de").unwrap().source, LayoutSource::Bcp47);
        assert_eq!(layout(4, 0, "de"), None);
        assert_eq!(layout(2, 0, "de DE"), None);
        assert_eq!(layout(2, 0, &"a".repeat(65)), None);
    }

    #[test]
    fn bad_arguments_are_refused() {
        assert_eq!(std::mem::size_of::<MysticTextField>(), 3, "mystic.h's layout");
        unsafe {
            assert_eq!(mystic_session_keyboard_layout(std::ptr::null(), 1, 0, c"x".as_ptr()), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_text(std::ptr::null_mut(), c"\n".as_ptr()), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_text(std::ptr::null_mut(), std::ptr::null()), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_text_field(std::ptr::null(), std::ptr::null_mut()), MYSTIC_ERR_INVALID_ARGUMENT);
        }
    }
}
