//! The client timing CSV: one row per picture shown, in the format of Nightjar's desktop
//! `timing_csv.rs` and Android's `nightjar-latency.csv`, so Rubylight's `timing_report.py` joins it
//! with the host record through the 0x5537 clock offset. Off unless `NIGHTJAR_TIMING_CSV` names a
//! file or folder. Rows never block the caller. The columns for the beam race, early decode and
//! DXGI frame statistics stay, empty, so a reader that goes by name sees the same header.

use std::collections::VecDeque;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use nightjar_core::session;
use nightjar_core::timing_record::{self as record, PendingRow, Record};
use rubylight_protocol::control::{HostTiming, HostTimingExtra};

/// The receiver's own columns, in `FrameLatencyStats.CSV_HEADER` order; the nine host columns
/// (`record::HEADER`) follow.
pub const OWN_COLUMNS: [&str; 32] = [
    "frame_number", "pts_us", "receive_ns", "decoder_input_ns", "decoder_output_ns",
    "render_ns", "release_ns", "status", "receive_to_input_ms", "input_to_output_ms", "output_to_render_ms",
    "receive_to_render_ms", "csv_rows_lost", "host_processing_ms",
    "decode_to_present_ms", "receive_to_present_ms",
    "decode_to_release_ms", "decode_interval_ms", "release_interval_ms",
    "fps_sample_ns", "received_fps", "released_fps", "shown_fps", "present_drops", "enqueue_ns", "queue_wait_ms",
    "host_present_to_sent_ms", "host_queue_ms", "host_encode_ms", "host_send_ms",
    "callback_received_ns", "callback_delay_ms",
];

/// The Android present scheduler's columns after the host's, in `FrameLatencyStats.CSV_HEADER`
/// order: the desktop has no such scheduler, so they are always empty.
pub const SCHEDULER_COLUMNS: [&str; 7] = [
    "sched_vsync_ns", "sched_hold_ms", "sched_late", "queue_depth", "residency_excess_ms", "in_flight", "drop_reason",
];

/// The desktop's own columns after those.
pub const EXTRA_COLUMNS: [&str; 20] = [
    "early", "first_block_ns", "due_ns", "present_begin_ns", "present_count", "stat_present_count", "stat_present_refresh",
    "stat_sync_refresh", "stat_sync_ns", "slices_decoded", "first_slice_ready_ns", "last_slice_ready_ns", "row_ordered",
    "scan_line_at_present", "in_vblank_at_present", "race_reason",
    "scan_start_ns", "present_ns", "mid_row_age_ns", "late_slices",
];

pub fn header() -> String {
    format!("{},{},{},{}\n", OWN_COLUMNS.join(","), record::HEADER, SCHEDULER_COLUMNS.join(","), EXTRA_COLUMNS.join(","))
}

/// Rows waiting for the writer.
const QUEUE: usize = 4096;

/// What the UI thread knows when a picture has been presented. Times are µs on the session
/// clock, 0 when unknown.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Row {
    pub number: u32,
    pub rtp: u32,
    /// The frame's first packet arrived.
    pub receive_us: u64,
    /// The frame was complete and queued for decoding.
    pub enqueue_us: u64,
    pub input_us: u64,
    /// Decoding finished.
    pub output_us: u64,
    /// The picture was handed to the display.
    pub render_us: u64,
    /// The host's processing latency in 1/10 ms (0 when not reported).
    pub host_latency: u16,
    /// Pictures replaced before they were shown, since the stream began.
    pub drops: u64,
    /// The clock offset (`client = host + offset`) and round trip, µs, when known.
    pub clock: Option<(i64, i64)>,
    /// When the pacer meant to present the picture, and when the presenter began on it (µs).
    pub due_us: u64,
    pub begin_us: u64,
}

enum Message {
    Row(Box<Row>),
    Reports(Vec<(HostTiming, Option<HostTimingExtra>)>),
}

/// The open file. Dropping it writes what is waiting and closes the file.
pub struct TimingCsv {
    sender: Option<SyncSender<Message>>,
    lost: Arc<AtomicU64>,
    writer: Option<JoinHandle<()>>,
}

/// A folder gets `nightjar-latency.csv` (Android's file name); anything else is the file.
pub fn resolve(path: &Path) -> PathBuf {
    if path.is_dir() { path.join("nightjar-latency.csv") } else { path.to_owned() }
}

impl TimingCsv {
    pub fn create(path: &Path) -> std::io::Result<Self> {
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir)?;
        }
        let mut file = BufWriter::new(File::create(path)?);
        file.write_all(header().as_bytes())?;
        file.flush()?;
        let (sender, inbox) = sync_channel(QUEUE);
        let lost = Arc::new(AtomicU64::new(0));
        let counter = lost.clone();
        let writer = std::thread::Builder::new()
            .name("timing-csv".into())
            .spawn(move || run(file, inbox, &counter))?;
        Ok(Self { sender: Some(sender), lost, writer: Some(writer) })
    }

    /// Queues one row. Never blocks; a full queue counts the row as lost.
    pub fn row(&self, row: Row) {
        self.send(Message::Row(Box::new(row)));
    }

    /// Hands over the records of a 0x5536 report.
    pub fn reports(&self, records: &[(HostTiming, Option<HostTimingExtra>)]) {
        self.send(Message::Reports(records.to_vec()));
    }

    fn send(&self, message: Message) {
        let Some(sender) = &self.sender else { return };
        match sender.try_send(message) {
            Ok(()) => {}
            Err(TrySendError::Full(Message::Row(_))) => {
                self.lost.fetch_add(1, Ordering::Relaxed);
            }
            // A lost report leaves empty host columns; the row is still written.
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
        }
    }

    /// Rows lost because the writer fell behind.
    pub fn lost(&self) -> u64 {
        self.lost.load(Ordering::Relaxed)
    }
}

impl Drop for TimingCsv {
    fn drop(&mut self) {
        self.sender = None;
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
        if self.lost() > 0 {
            eprintln!("nightjar: the timing CSV lost {} rows (the writer fell behind)", self.lost());
        }
    }
}

fn run(mut file: BufWriter<File>, inbox: std::sync::mpsc::Receiver<Message>, lost: &AtomicU64) {
    let mut record = Record::default();
    let mut previous_output = 0u64;
    let mut shown = ShownFps::default();
    // The desktop columns of the rows the record holds, in the order it gives them back.
    let mut extras: VecDeque<String> = VecDeque::new();
    loop {
        let done = match inbox.recv_timeout(Duration::from_millis(100)) {
            Ok(Message::Row(row)) => {
                let fps = shown.push(row.render_us);
                let line = own_fields(&row, lost.load(Ordering::Relaxed), previous_output, fps);
                previous_output = row.output_us;
                extras.push_back(format!("{},{}", scheduler_fields(), extra_fields(&row)));
                record.push(PendingRow {
                    number: row.number,
                    line,
                    rtp_timestamp: row.rtp,
                    clock: row.clock,
                    due_us: session::now_us() + record::ROW_DELAY_US,
                });
                false
            }
            Ok(Message::Reports(reports)) => {
                record.add_reports(reports);
                false
            }
            Err(RecvTimeoutError::Timeout) => false,
            Err(RecvTimeoutError::Disconnected) => true,
        };
        let now = if done { u64::MAX } else { session::now_us() };
        let rows = record.take_due(now);
        for line in &rows {
            let extra = extras.pop_front().unwrap_or_else(|| extra_fields(&Row::default()));
            let _ = writeln!(file, "{line},{extra}");
        }
        if !rows.is_empty() || done {
            let _ = file.flush();
        }
        if done {
            return;
        }
    }
}

fn timestamp(us: u64) -> String {
    if us == 0 { String::new() } else { (us * 1000).to_string() }
}

/// Milliseconds with six decimals between two times, empty when either is missing or the end
/// is before the start (as the Android file does).
fn duration(start_us: u64, end_us: u64) -> String {
    if start_us == 0 || end_us == 0 || end_us < start_us {
        return String::new();
    }
    milliseconds((end_us - start_us) * 1000)
}

fn milliseconds(ns: u64) -> String {
    format!("{}.{:06}", ns / 1_000_000, ns % 1_000_000)
}

/// Shown pictures per second over the last second of presents.
#[derive(Default)]
struct ShownFps {
    renders: VecDeque<u64>,
}

impl ShownFps {
    /// Adds a present and gives the rate when the window spans two or more.
    fn push(&mut self, render_us: u64) -> Option<f64> {
        self.renders.push_back(render_us);
        while self.renders.front().is_some_and(|first| render_us.saturating_sub(*first) > 1_000_000) {
            self.renders.pop_front();
        }
        let span = render_us.saturating_sub(*self.renders.front()?);
        (self.renders.len() >= 2 && span > 0).then(|| (self.renders.len() - 1) as f64 * 1e6 / span as f64)
    }
}

/// The receiver's own 32 columns of one row, comma separated.
pub fn own_fields(row: &Row, lost: u64, previous_output_us: u64, shown_fps: Option<f64>) -> String {
    let mut fields = vec![String::new(); OWN_COLUMNS.len()];
    let mut set = |name: &str, value: String| {
        let at = OWN_COLUMNS.iter().position(|c| *c == name).expect("a known column");
        fields[at] = value;
    };
    let output_to_render = duration(row.output_us, row.render_us);
    let receive_to_render = duration(row.receive_us, row.render_us);
    set("frame_number", row.number.to_string());
    set("pts_us", record::rtp_host_us(row.rtp).to_string());
    set("receive_ns", timestamp(row.receive_us));
    set("decoder_input_ns", timestamp(row.input_us));
    set("decoder_output_ns", timestamp(row.output_us));
    set("render_ns", timestamp(row.render_us));
    set("status", "rendered".into());
    set("receive_to_input_ms", duration(row.receive_us, row.input_us));
    set("input_to_output_ms", duration(row.input_us, row.output_us));
    set("output_to_render_ms", output_to_render.clone());
    set("receive_to_render_ms", receive_to_render.clone());
    set("csv_rows_lost", lost.to_string());
    if row.host_latency != 0 {
        set("host_processing_ms", milliseconds(u64::from(row.host_latency) * 100_000));
    }
    set("decode_to_present_ms", output_to_render);
    set("receive_to_present_ms", receive_to_render);
    set("decode_interval_ms", duration(previous_output_us, row.output_us));
    set("fps_sample_ns", timestamp(row.render_us));
    if let Some(fps) = shown_fps {
        set("shown_fps", format!("{fps:.2}"));
    }
    set("present_drops", row.drops.to_string());
    set("enqueue_ns", timestamp(row.enqueue_us));
    set("queue_wait_ms", duration(row.enqueue_us, row.input_us));
    fields.join(",")
}

/// The scheduler columns of one row: all empty.
pub fn scheduler_fields() -> String {
    vec![""; SCHEDULER_COLUMNS.len()].join(",")
}

/// The desktop columns of one row, comma separated: decoded whole, and only the pacer's times.
pub fn extra_fields(row: &Row) -> String {
    let mut fields = vec![String::new(); EXTRA_COLUMNS.len()];
    fields[0] = "0".into();
    fields[2] = timestamp(row.due_us);
    fields[3] = timestamp(row.begin_us);
    fields.join(",")
}

use crate::{MysticSession, MYSTIC_ERR_INVALID_ARGUMENT, MYSTIC_ERR_NOT_STARTED};
use nightjar_core::control::ClientMessage;
use rubylight_protocol::control::{HostTimingRequest, HOST_TIMING_MESSAGE_TYPE};
use std::ffi::{c_char, CStr};

/// What the listener and the app share.
#[derive(Default)]
pub(crate) struct TimingOutput {
    pub csv: Option<TimingCsv>,
    pub host_reports: bool,
}
impl TimingOutput {
    pub fn announce(&mut self, messages: &[u16]) {
        self.host_reports = messages.contains(&HOST_TIMING_MESSAGE_TYPE);
    }
}

/// One picture shown, on the clock of `mystic_clock_now_us`; 0 where unknown.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct MysticTimingRow {
    pub number: u32,
    pub rtp: u32,
    pub receive_us: u64,
    pub enqueue_us: u64,
    pub input_us: u64,
    pub output_us: u64,
    pub render_us: u64,
    pub host_latency: u16,
    pub drops: u64,
    pub due_us: u64,
    pub begin_us: u64,
}

/// Opens the CSV at `path` (a folder gets `nightjar-latency.csv`) and asks the host for its reports.
#[no_mangle]
pub unsafe extern "C" fn mystic_session_timing_csv_open(handle: *const MysticSession, path: *const c_char) -> i32 {
    let Some(handle) = handle.as_ref() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    if path.is_null() { return MYSTIC_ERR_INVALID_ARGUMENT; }
    let Some(session) = handle.session.as_ref() else { return MYSTIC_ERR_NOT_STARTED };
    let Ok(text) = CStr::from_ptr(path).to_str() else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let Ok(csv) = TimingCsv::create(&resolve(Path::new(text))) else { return MYSTIC_ERR_INVALID_ARGUMENT };
    let mut output = handle.timing.lock().unwrap_or_else(|e| e.into_inner());
    if output.host_reports {
        let _ = session.send(ClientMessage::HostTimingRequest(HostTimingRequest { enabled: true }));
    }
    output.csv = Some(csv);
    0
}

#[no_mangle]
pub unsafe extern "C" fn mystic_session_timing_row(handle: *const MysticSession, row: *const MysticTimingRow) {
    let (Some(handle), Some(row)) = (handle.as_ref(), row.as_ref()) else { return };
    let clock = handle.clock.lock().unwrap_or_else(|e| e.into_inner()).offset(row.enqueue_us as i64);
    let output = handle.timing.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(csv) = &output.csv {
        csv.row(Row { number: row.number, rtp: row.rtp, receive_us: row.receive_us, enqueue_us: row.enqueue_us, input_us: row.input_us,
            output_us: row.output_us, render_us: row.render_us, host_latency: row.host_latency, drops: row.drops, clock,
            due_us: row.due_us, begin_us: row.begin_us });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_matches_nightjars_column_order() {
        let header = header();
        assert!(header.starts_with("frame_number,pts_us,receive_ns,"));
        assert!(header.contains("callback_delay_ms,"));
        assert!(header.trim_end().ends_with("mid_row_age_ns,late_slices"));
        assert_eq!(header.trim_end().split(',').count(), OWN_COLUMNS.len() + record::HEADER.split(',').count() + SCHEDULER_COLUMNS.len() + EXTRA_COLUMNS.len());
    }

    #[test]
    fn a_row_has_every_column_and_its_times() {
        let row = Row { number: 7, rtp: 90_000, receive_us: 1000, input_us: 1500, output_us: 3000, render_us: 11_000, due_us: 3100, begin_us: 3200, ..Default::default() };
        let own = own_fields(&row, 0, 0, Some(120.0));
        assert_eq!(own.split(',').count(), OWN_COLUMNS.len());
        let at = |name: &str| own.split(',').nth(OWN_COLUMNS.iter().position(|c| *c == name).unwrap()).unwrap().to_owned();
        assert_eq!(at("frame_number"), "7");
        assert_eq!(at("receive_to_render_ms"), "10.000000");
        assert_eq!(at("output_to_render_ms"), "8.000000");
        let extra = extra_fields(&row);
        assert_eq!(extra.split(',').count(), EXTRA_COLUMNS.len());
        assert!(extra.starts_with("0,,3100000,3200000,"));
    }

    #[test]
    fn a_file_gets_the_header_and_rows_then_closes() {
        let path = std::env::temp_dir().join(format!("mystic-timing-{}.csv", std::process::id()));
        let csv = TimingCsv::create(&path).unwrap();
        csv.row(Row { number: 1, rtp: 90, render_us: 10, ..Default::default() });
        drop(csv);
        let text = std::fs::read_to_string(&path).unwrap();
        std::fs::remove_file(&path).ok();
        let mut lines = text.lines();
        let columns = lines.next().unwrap().split(',').count();
        assert_eq!(lines.next().unwrap().split(',').count(), columns);
    }
}
