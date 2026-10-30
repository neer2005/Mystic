//! Text-only sync uses Nightjar's token/echo rules. One pending host copy bounds memory.
use crate::MysticSession;
use nightjar_core::control::clipboard_sync::{ClipboardItem, ClipboardSync, Local, Received};
use nightjar_core::control::{ClientMessage, ControlEvent};
use rubylight_protocol::clipboard_sync::{CLIPBOARD_SYNC_MESSAGE_TYPE, MAX_PAYLOAD_BYTES};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr};
use std::time::Instant;

pub(crate) const MANUAL_LIMIT: usize = 1024 * 1024;
pub(crate) fn validate_text(text: &str, limit: usize) -> Result<(), String> {
    if text.len() > limit {
        return Err("Clipboard text is too large.".into());
    }
    if text.contains('\0') {
        return Err("Clipboard text contains an unsupported NUL character.".into());
    }
    Ok(())
}

#[derive(Default)]
pub(crate) struct ClipboardState {
    announced: bool,
    foreground: bool,
    rules: Option<ClipboardSync>,
    pending: Option<String>,
}
impl ClipboardState {
    pub fn announce(&mut self, messages: &[u16]) {
        self.announced = messages.contains(&CLIPBOARD_SYNC_MESSAGE_TYPE);
    }
    pub fn receive(&mut self, event: ControlEvent) {
        let ControlEvent::ClipboardSync(frame) = event else {
            return;
        };
        if !self.foreground {
            return;
        }
        if let Some(rules) = &mut self.rules {
            if let Received::Apply(ClipboardItem::Text(text)) =
                rules.received(frame, Instant::now())
            {
                if text.len() <= MAX_PAYLOAD_BYTES {
                    self.pending = Some(text);
                }
            }
        }
    }
    fn step(
        &mut self,
        active: bool,
        baseline: bool,
        local: Option<String>,
    ) -> Result<(Vec<ClientMessage>, Value), String> {
        if !active {
            self.foreground = false;
            self.pending = None;
            return Ok((vec![], json!({"available":self.announced,"text":null})));
        }
        if let Some(text) = &local {
            validate_text(text, MAX_PAYLOAD_BYTES)?;
        }
        if !self.announced {
            return Ok((vec![], json!({"available":false,"text":null})));
        }
        let mut send = Vec::new();
        let newly_active = !self.foreground;
        self.foreground = true;
        if self.rules.is_none() {
            let rules = ClipboardSync::new(false);
            send.push(rules.hello());
            self.rules = Some(rules);
        }
        let rules = self.rules.as_mut().unwrap();
        if baseline || newly_active {
            self.pending = None;
            rules.baseline(local.map(ClipboardItem::Text));
        } else if let Some(text) = local {
            match rules.local(ClipboardItem::Text(text), Instant::now()) {
                Local::Send(message) => {
                    // A newly observed local copy wins over an older pending host copy.
                    self.pending = None;
                    send.push(message);
                }
                Local::Skip => {}
                Local::TooLarge(_) => {
                    return Err(
                        "This copy is too large for automatic sync. Use Send Text to Host.".into(),
                    )
                }
            }
        }
        Ok((send, json!({"available":true,"text":self.pending.take()})))
    }
}

/// Serialized session-worker call. JSON is bounded before parsing. Text never goes to logs.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_clipboard_step(
    handle: *const MysticSession,
    request: *const c_char,
) -> *mut c_char {
    crate::host::envelope((|| {
        let handle = handle.as_ref().ok_or("No stream is running.")?;
        let session = handle.session.as_ref().ok_or("No stream is running.")?;
        if request.is_null() {
            return Err("Missing clipboard request.".into());
        }
        let bytes = CStr::from_ptr(request).to_bytes();
        if bytes.len() > MAX_PAYLOAD_BYTES * 6 + 256 {
            return Err("Clipboard request is too large.".into());
        }
        let value: Value =
            serde_json::from_slice(bytes).map_err(|_| "Invalid clipboard request.")?;
        let active = value["active"]
            .as_bool()
            .ok_or("Missing clipboard active state.")?;
        let baseline = value["baseline"].as_bool().unwrap_or(false);
        let local = if value["text"].is_null() {
            None
        } else {
            Some(
                value["text"]
                    .as_str()
                    .ok_or("Invalid clipboard text.")?
                    .to_owned(),
            )
        };
        let (messages, result) = {
            handle
                .clipboard
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .step(active, baseline, local)?
        };
        // Never hold the clipboard mutex while taking the control-session lock.
        for message in messages {
            session
                .send(message)
                .map_err(|_| "The host did not accept clipboard sync.")?;
        }
        Ok(result)
    })())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rubylight_protocol::clipboard_sync::{Frame, KIND_PNG, KIND_TEXT};
    fn frame(token: u32, text: &str) -> ControlEvent {
        ControlEvent::ClipboardSync(Frame {
            kind: KIND_TEXT,
            token,
            payload: text.as_bytes().to_vec(),
        })
    }
    #[test]
    fn baseline_never_sends_existing_text_and_received_copy_does_not_echo() {
        let mut sync = ClipboardState::default();
        sync.announce(&[CLIPBOARD_SYNC_MESSAGE_TYPE]);
        let (sent, _) = sync
            .step(true, true, Some("already copied".into()))
            .unwrap();
        assert_eq!(sent.len(), 1);
        assert!(matches!(&sent[0],ClientMessage::ClipboardSync(f) if f.is_hello()));
        sync.receive(frame(42, "host text"));
        let (_, result) = sync.step(true, false, None).unwrap();
        assert_eq!(result["text"], "host text");
        assert!(sync
            .step(true, false, Some("host text".into()))
            .unwrap()
            .0
            .is_empty());
        let (sent, _) = sync.step(true, false, Some("new local".into())).unwrap();
        let ClientMessage::ClipboardSync(sent) = sent[0].clone() else {
            panic!()
        };
        sync.receive(ControlEvent::ClipboardSync(sent));
        assert!(sync.step(true, false, None).unwrap().1["text"].is_null());
    }
    #[test]
    fn background_pause_drops_pending_copies_and_resumes_with_a_new_baseline() {
        let mut sync = ClipboardState::default();
        sync.announce(&[CLIPBOARD_SYNC_MESSAGE_TYPE]);
        sync.step(true, true, None).unwrap();
        sync.receive(frame(1, "old"));
        sync.step(false, false, None).unwrap();
        sync.receive(frame(2, "background"));
        let (sent, result) = sync.step(true, true, Some("private local".into())).unwrap();
        assert!(sent.is_empty());
        assert!(result["text"].is_null());
        sync.receive(frame(3, "new host"));
        assert_eq!(sync.step(true, false, None).unwrap().1["text"], "new host");
    }
    #[test]
    fn text_only_coalesces_and_validates_utf8_bytes() {
        let mut sync = ClipboardState::default();
        sync.announce(&[CLIPBOARD_SYNC_MESSAGE_TYPE]);
        sync.step(true, true, None).unwrap();
        for token in 0..100 {
            sync.receive(frame(token, "last"));
        }
        sync.receive(frame(101, "newest"));
        sync.receive(ControlEvent::ClipboardSync(Frame {
            kind: KIND_PNG,
            token: 999,
            payload: vec![1, 2, 3],
        }));
        assert_eq!(sync.step(true, false, None).unwrap().1["text"], "newest");
        assert!(validate_text("a\0b", MANUAL_LIMIT).is_err());
        assert!(validate_text(&"é".repeat(10), 19).is_err());
        assert!(validate_text(&"x".repeat(MANUAL_LIMIT + 1), MANUAL_LIMIT).is_err());
        assert!(sync
            .step(true, false, Some("x".repeat(MAX_PAYLOAD_BYTES + 1)))
            .is_err());
        let mut unsupported = ClipboardState::default();
        assert_eq!(
            unsupported.step(true, true, None).unwrap().1["available"],
            false
        );
    }
    #[test]
    fn a_new_local_copy_wins_over_pending_host_text() {
        let mut sync = ClipboardState::default();
        sync.announce(&[CLIPBOARD_SYNC_MESSAGE_TYPE]);
        sync.step(true, true, None).unwrap();
        sync.receive(frame(10, "older host copy"));
        let (sent, result) = sync
            .step(true, false, Some("new local copy".into()))
            .unwrap();
        assert_eq!(sent.len(), 1);
        assert!(result["text"].is_null());
    }
}
