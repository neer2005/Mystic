//! Host cursor shapes (control messages 0x5540 and 0x5541) for a local pointer drawn by the
//! app in desktop control, as Nightjar's desktop client draws them (`stream/cursor.rs`). The
//! host then leaves its cursor out of the video, so the pointer moves without video delay.
//! Shapes are kept in order: an image defines an id that a later show refers to.
use crate::{MysticSession, MYSTIC_ERR_BUFFER_TOO_SMALL, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED, MYSTIC_ERR_UNIMPLEMENTED};
use nightjar_core::control::{ClientMessage, ControlEvent, CursorShape};
use std::collections::VecDeque;

/// The largest image: 96 by 96 RGBA pixels.
pub const MYSTIC_CURSOR_MAX_PIXEL_BYTES: usize = 96 * 96 * 4;
/// Shapes waiting for the app; the host sends one only when the cursor changes. Past this the
/// oldest is dropped, and a later show of an image lost that way draws the default pointer.
const QUEUE: usize = 128;

pub const MYSTIC_CURSOR_HIDE: u8 = 0;
pub const MYSTIC_CURSOR_DEFAULT: u8 = 1;
pub const MYSTIC_CURSOR_SHOW: u8 = 2;
pub const MYSTIC_CURSOR_IMAGE: u8 = 3;
/// The host sent a shape that broke the format; draw the default pointer.
pub const MYSTIC_CURSOR_REJECTED: u8 = 4;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MysticCursorShape {
    /// `MYSTIC_CURSOR_*`.
    pub kind: u8,
    pub width: u16,
    pub height: u16,
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    /// The host display's scale in percent (100 = 96 DPI).
    pub scale_percent: u16,
    /// The cache id of a show or image.
    pub id: u32,
    /// Straight-alpha sRGB RGBA bytes written for an image, rows top to bottom.
    pub pixel_bytes: u32,
}

#[derive(Default)]
pub(crate) struct CursorQueue {
    pending: VecDeque<Option<CursorShape>>,
}
impl CursorQueue {
    pub fn receive(&mut self, event: ControlEvent) {
        let shape = match event {
            ControlEvent::CursorShape(shape) => Some(shape),
            ControlEvent::CursorShapeRejected(_) => None,
            _ => return,
        };
        if self.pending.len() == QUEUE {
            self.pending.pop_front();
        }
        self.pending.push_back(shape);
    }
    fn take(&mut self, out: &mut MysticCursorShape, pixels: &mut [u8]) -> bool {
        let Some(next) = self.pending.pop_front() else { return false };
        *out = MysticCursorShape::default();
        match next {
            None => out.kind = MYSTIC_CURSOR_REJECTED,
            Some(CursorShape::Hide) => out.kind = MYSTIC_CURSOR_HIDE,
            Some(CursorShape::Default) => out.kind = MYSTIC_CURSOR_DEFAULT,
            Some(CursorShape::Show { id }) => {
                out.kind = MYSTIC_CURSOR_SHOW;
                out.id = id;
            }
            Some(CursorShape::Image { id, width, height, hotspot_x, hotspot_y, scale_percent, rgba }) => {
                // The engine validated the size against the edges; a mismatch is never copied.
                if rgba.len() > pixels.len() || rgba.len() != usize::from(width) * usize::from(height) * 4 {
                    out.kind = MYSTIC_CURSOR_REJECTED;
                    return true;
                }
                pixels[..rgba.len()].copy_from_slice(&rgba);
                *out = MysticCursorShape {
                    kind: MYSTIC_CURSOR_IMAGE,
                    width,
                    height,
                    hotspot_x,
                    hotspot_y,
                    scale_percent,
                    id,
                    pixel_bytes: rgba.len() as u32,
                };
            }
        }
        true
    }
}

/// Starts or stops cursor shapes. MYSTIC_ERR_UNIMPLEMENTED when the host does not take them;
/// waiting shapes are dropped either way, since the host starts its cache again.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_cursor_shapes(handle: *const MysticSession, enabled: bool) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let Some(session) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    handle.cursor.lock().unwrap_or_else(|e| e.into_inner()).pending.clear();
    match session.send(ClientMessage::CursorShapeRequest { enabled }) {
        Ok(()) => 0,
        Err(_) => MYSTIC_ERR_UNIMPLEMENTED,
    }
}

/// Takes the oldest waiting shape: 1 when one was written, 0 when none waits. `pixels` must
/// hold MYSTIC_CURSOR_MAX_PIXEL_BYTES. Serialized with session start and stop.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_take_cursor(
    handle: *const MysticSession,
    out: *mut MysticCursorShape,
    pixels: *mut u8,
    capacity: usize,
) -> i32 {
    if out.is_null() || pixels.is_null() {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    if capacity < MYSTIC_CURSOR_MAX_PIXEL_BYTES {
        return MYSTIC_ERR_BUFFER_TOO_SMALL;
    }
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let mut queue = handle.cursor.lock().unwrap_or_else(|e| e.into_inner());
    i32::from(queue.take(&mut *out, std::slice::from_raw_parts_mut(pixels, capacity)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn take(queue: &mut CursorQueue) -> Option<(MysticCursorShape, Vec<u8>)> {
        let mut out = MysticCursorShape::default();
        let mut pixels = vec![0; MYSTIC_CURSOR_MAX_PIXEL_BYTES];
        queue.take(&mut out, &mut pixels).then(|| (out, pixels[..out.pixel_bytes as usize].to_vec()))
    }

    #[test]
    fn shapes_arrive_in_order_with_their_pixels() {
        let mut queue = CursorQueue::default();
        queue.receive(ControlEvent::CursorShape(CursorShape::Image {
            id: 7, width: 2, height: 1, hotspot_x: 1, hotspot_y: 0, scale_percent: 150, rgba: (0..8).collect(),
        }));
        queue.receive(ControlEvent::CursorShape(CursorShape::Hide));
        queue.receive(ControlEvent::CursorShape(CursorShape::Show { id: 7 }));
        queue.receive(ControlEvent::CursorShapeRejected("short header"));
        queue.receive(ControlEvent::CursorShape(CursorShape::Default));
        let (image, pixels) = take(&mut queue).unwrap();
        assert_eq!(image, MysticCursorShape {
            kind: MYSTIC_CURSOR_IMAGE, width: 2, height: 1, hotspot_x: 1, hotspot_y: 0, scale_percent: 150, id: 7, pixel_bytes: 8,
        });
        assert_eq!(pixels, (0..8).collect::<Vec<u8>>());
        assert_eq!(take(&mut queue).unwrap().0.kind, MYSTIC_CURSOR_HIDE);
        assert_eq!(take(&mut queue).unwrap().0, MysticCursorShape { kind: MYSTIC_CURSOR_SHOW, id: 7, ..Default::default() });
        assert_eq!(take(&mut queue).unwrap().0.kind, MYSTIC_CURSOR_REJECTED);
        assert_eq!(take(&mut queue).unwrap().0.kind, MYSTIC_CURSOR_DEFAULT);
        assert!(take(&mut queue).is_none());
    }

    #[test]
    fn a_flood_keeps_the_newest_and_other_events_are_ignored() {
        let mut queue = CursorQueue::default();
        queue.receive(ControlEvent::Rumble { controller: 0, low_frequency: 1, high_frequency: 1 });
        for id in 1..=QUEUE as u32 + 10 {
            queue.receive(ControlEvent::CursorShape(CursorShape::Show { id }));
        }
        assert_eq!(queue.pending.len(), QUEUE);
        assert_eq!(take(&mut queue).unwrap().0.id, 11);
    }

    #[test]
    fn bad_arguments_are_refused() {
        assert_eq!(std::mem::size_of::<MysticCursorShape>(), 20, "mystic.h's layout");
        let mut out = MysticCursorShape::default();
        let mut small = [0u8; 4];
        unsafe {
            assert_eq!(mystic_session_take_cursor(std::ptr::null(), &mut out, small.as_mut_ptr(), small.len()), MYSTIC_ERR_BUFFER_TOO_SMALL);
            assert_eq!(mystic_session_take_cursor(std::ptr::null(), std::ptr::null_mut(), small.as_mut_ptr(), 4), MYSTIC_ERR_INVALID_ARGUMENT);
            assert_eq!(mystic_session_cursor_shapes(std::ptr::null(), true), MYSTIC_ERR_INVALID_ARGUMENT);
        }
    }
}
