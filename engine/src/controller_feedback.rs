//! Latest motor state per controller/kind: host floods never grow a queue.
use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT};
use nightjar_core::control::ControlEvent;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MysticControllerFeedback {
    pub slot: u8,
    /// 1: handle rumble (low/high frequency), 2: trigger rumble (left/right).
    pub kind: u8,
    pub first: u16,
    pub second: u16,
    pub epoch: u64,
}

#[derive(Default)]
pub(crate) struct FeedbackMailbox {
    pending: [[Option<MysticControllerFeedback>; 2]; 4],
    epochs: [u64; 4],
}
impl FeedbackMailbox {
    pub fn receive(&mut self, event: ControlEvent) {
        let (slot, kind, first, second) = match event {
            ControlEvent::Rumble {
                controller,
                low_frequency,
                high_frequency,
            } => (controller, 1, low_frequency, high_frequency),
            ControlEvent::RumbleTriggers {
                controller,
                left,
                right,
            } => (controller, 2, left, right),
            _ => return,
        };
        if slot < 4 {
            self.pending[slot as usize][kind as usize - 1] = Some(MysticControllerFeedback {
                slot: slot as u8,
                kind,
                first,
                second,
                epoch: self.epochs[slot as usize],
            });
        }
    }
    pub fn clear_slot(&mut self, slot: u8, epoch: u64) {
        self.epochs[slot as usize] = epoch;
        self.pending[slot as usize] = [None; 2];
    }
    fn take(&mut self, out: &mut [MysticControllerFeedback]) -> usize {
        let mut count = 0;
        for kinds in &mut self.pending {
            for pending in kinds {
                if count == out.len() {
                    return count;
                }
                if let Some(value) = pending.take() {
                    out[count] = value;
                    count += 1;
                }
            }
        }
        count
    }
}

/// Serialized with session start/stop; output storage is caller-owned.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_take_controller_feedback(
    handle: *const MysticSession,
    out: *mut MysticControllerFeedback,
    capacity: usize,
) -> i32 {
    if out.is_null() || capacity == 0 || capacity > 8 {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    }
    let Some(handle) = handle.as_ref() else {
        return MYSTIC_ERR_INVALID_ARGUMENT;
    };
    let mut mailbox = handle.feedback.lock().unwrap_or_else(|e| e.into_inner());
    mailbox.take(std::slice::from_raw_parts_mut(out, capacity)) as i32
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn coalesces_per_motor_and_preserves_zero_stops() {
        let mut mailbox = FeedbackMailbox::default();
        for power in 0..1000 {
            mailbox.receive(ControlEvent::Rumble {
                controller: 2,
                low_frequency: power,
                high_frequency: 42,
            });
        }
        mailbox.receive(ControlEvent::RumbleTriggers {
            controller: 2,
            left: 123,
            right: 456,
        });
        mailbox.receive(ControlEvent::Rumble {
            controller: 2,
            low_frequency: 0,
            high_frequency: 0,
        });
        mailbox.receive(ControlEvent::Rumble {
            controller: 16,
            low_frequency: 65535,
            high_frequency: 65535,
        });
        let mut out = [MysticControllerFeedback::default(); 8];
        assert_eq!(mailbox.take(&mut out), 2);
        assert_eq!(
            out[0],
            MysticControllerFeedback {
                slot: 2,
                kind: 1,
                first: 0,
                second: 0,
                epoch: 0
            }
        );
        assert_eq!(
            out[1],
            MysticControllerFeedback {
                slot: 2,
                kind: 2,
                first: 123,
                second: 456,
                epoch: 0
            }
        );
        assert_eq!(mailbox.take(&mut out), 0);
    }
    #[test]
    fn arrivals_clear_stale_feedback_and_small_reads_keep_other_slots() {
        let mut mailbox = FeedbackMailbox::default();
        for slot in 0..4 {
            mailbox.receive(ControlEvent::Rumble {
                controller: slot,
                low_frequency: 1,
                high_frequency: 2,
            });
        }
        mailbox.clear_slot(0, 7);
        let mut out = [MysticControllerFeedback::default(); 1];
        assert_eq!(mailbox.take(&mut out), 1);
        assert_eq!(out[0].slot, 1);
        assert_eq!(mailbox.take(&mut out), 1);
        assert_eq!(out[0].slot, 2);
        assert_eq!(mailbox.take(&mut out), 1);
        assert_eq!(out[0].slot, 3);
        assert_eq!(mailbox.take(&mut out), 0);
    }
    #[test]
    fn listener_reaches_c_poll_with_slot_epoch_and_full_amplitudes() {
        use crate::{mystic_session_free, mystic_session_new, ListenerAdapter, MysticCallbacks};
        use nightjar_core::session::Listener;
        unsafe {
            let handle = mystic_session_new();
            (*handle).feedback.lock().unwrap().clear_slot(3, 123456789);
            let listener = ListenerAdapter {
                callbacks: MysticCallbacks::default(),
                feedback: (*handle).feedback.clone(),
            };
            listener.control_event(ControlEvent::Rumble {
                controller: 3,
                low_frequency: 0x1234,
                high_frequency: 65535,
            });
            let mut out = [MysticControllerFeedback::default(); 8];
            assert_eq!(
                mystic_session_take_controller_feedback(handle, out.as_mut_ptr(), 8),
                1
            );
            assert_eq!(
                out[0],
                MysticControllerFeedback {
                    slot: 3,
                    kind: 1,
                    first: 0x1234,
                    second: 65535,
                    epoch: 123456789
                }
            );
            assert_eq!(std::mem::size_of::<MysticControllerFeedback>(), 16);
            assert_eq!(
                mystic_session_take_controller_feedback(handle, out.as_mut_ptr(), 8),
                0
            );
            mystic_session_free(handle);
        }
    }
}
