//! A PC's Files page without its drawing: Nightjar's `ui/files.rs`. Asks the PC what this device
//! may do, lists its transfer folder, and sends and downloads through nightjar-core's transfer
//! list: one upload and two downloads at a time, and a retry starts from the first byte. Each
//! transfer runs on its own thread; the app polls a snapshot. Freeing the page cancels every
//! transfer that has not finished, which leaves no partial file on either side.
use crate::host::{envelope_for, MysticHost};
use nightjar_core::http::transfers::{partial_path, upload_name, Direction, Problem, Start, State, Transfer, Transfers};
use nightjar_core::http::{Availability, Error, Feature, FileError, FileList, HostClient, Reason, TransferCancel, Uploaded};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, CStr};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

/// The calls the page makes; `HostClient` in the app, a fake in tests.
trait FileHost: Send + Sync + 'static {
    /// Whether this device may send and download.
    fn access(&self) -> Result<(Availability, Availability), Error>;
    fn list(&self) -> Result<FileList, FileError>;
    fn upload(&self, name: &str, file: &mut dyn Read, length: u64, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<Uploaded, FileError>;
    fn download(&self, name: &str, listed: u64, dest: &Path, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<u64, FileError>;
}
impl FileHost for HostClient {
    fn access(&self) -> Result<(Availability, Availability), Error> {
        let capabilities = self.server_info_https()?.capabilities.with_native(&self.native_capabilities_with_files()?);
        Ok((capabilities.availability(Feature::FileUpload), capabilities.availability(Feature::FileDownload)))
    }
    fn list(&self) -> Result<FileList, FileError> {
        self.list_files()
    }
    fn upload(&self, name: &str, file: &mut dyn Read, length: u64, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<Uploaded, FileError> {
        self.upload_file(name, file, length, progress, stop)
    }
    fn download(&self, name: &str, listed: u64, dest: &Path, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<u64, FileError> {
        self.download_to_path(name, listed, dest, progress, stop)
    }
}

enum Event {
    Access(Result<(Availability, Availability), Error>),
    /// `ask` numbers the read, so an older answer that lands later is dropped.
    Listed { ask: u64, result: Result<FileList, FileError> },
    Progress { id: u64, done: u64, total: u64 },
    Uploaded { id: u64, result: Result<Uploaded, FileError> },
    Downloaded { id: u64, result: Result<u64, FileError> },
}
#[derive(Clone, Debug, PartialEq)]
enum Access {
    Checking,
    Known { upload: Availability, download: Availability },
    Failed(String),
}
struct Page {
    api: Arc<dyn FileHost>,
    access: Access,
    list: Option<Result<FileList, (Problem, String)>>,
    listing: Option<u64>,
    asks: u64,
    transfers: Transfers,
    sources: HashMap<u64, PathBuf>,
    folder: PathBuf,
    notices: Vec<String>,
    sender: Sender<Event>,
    events: Receiver<Event>,
}
impl Drop for Page {
    fn drop(&mut self) {
        // The workers end with `Cancelled` and report to a channel nobody reads.
        self.transfers.cancel_all();
    }
}
impl Page {
    fn new(api: Arc<dyn FileHost>, folder: PathBuf) -> Self {
        let (sender, events) = channel();
        let mut page = Self { api, access: Access::Checking, list: None, listing: None, asks: 0, transfers: Transfers::new(),
            sources: HashMap::new(), folder, notices: Vec::new(), sender, events };
        page.check_again();
        page
    }
    fn check_again(&mut self) {
        if self.access == Access::Checking && self.asks > 0 {
            return;
        }
        self.asks += 1;
        self.access = Access::Checking;
        let api = self.api.clone();
        if let Err(e) = self.spawn("files access", move || Event::Access(api.access())) {
            self.access = Access::Failed(e);
        }
    }
    fn spawn(&self, name: &str, work: impl FnOnce() -> Event + Send + 'static) -> Result<(), String> {
        let sender = self.sender.clone();
        std::thread::Builder::new().name(name.into()).spawn(move || { let _ = sender.send(work()); }).map(drop).map_err(|e| e.to_string())
    }
    fn read_folder(&mut self) {
        if self.listing.is_some() {
            return;
        }
        self.asks += 1;
        let ask = self.asks;
        let api = self.api.clone();
        match self.spawn("files list", move || Event::Listed { ask, result: api.list() }) {
            Ok(()) => self.listing = Some(ask),
            Err(e) => self.list = Some(Err((Problem::Local, e))),
        }
    }
    fn send(&mut self, paths: Vec<PathBuf>) {
        for path in paths {
            let shown = path.display().to_string();
            match std::fs::metadata(&path) {
                Ok(meta) if meta.is_file() => {
                    let local = path.file_name().map_or_else(|| shown.clone(), |n| n.to_string_lossy().into_owned());
                    let id = self.transfers.queue_upload(&local, meta.len());
                    self.sources.insert(id, path);
                }
                Ok(_) => self.notices.push(format!("{shown} was not sent: it is not a file.")),
                Err(e) => self.notices.push(format!("{shown} was not sent: {e}")),
            }
        }
        self.pump();
    }
    fn download(&mut self, name: &str, size: u64) {
        // A canceled or failed download keeps its name too: trying it again writes to it.
        let taken: Vec<&str> = self.transfers.items().iter().filter(|t| t.direction == Direction::Download).map(|t| t.local_name.as_str()).collect();
        let local = free_name(&self.folder, &upload_name(name), &taken);
        self.transfers.queue_download(name, &local, size);
        self.pump();
    }
    fn pump(&mut self) {
        for start in self.transfers.start_next() {
            let id = start.id;
            let started = match start.direction {
                Direction::Upload => {
                    let source = self.sources.get(&id).cloned();
                    self.spawn("file upload", self.uploader(start, source))
                }
                Direction::Download => {
                    let dest = self.folder.join(&start.local_name);
                    self.spawn("file download", self.downloader(start, dest))
                }
            };
            if let Err(e) = started {
                let error = FileError::Local(std::io::Error::other(e));
                match self.transfers.get(id).map(|t| t.direction) {
                    Some(Direction::Upload) => self.transfers.finish_upload(id, Err(error)),
                    _ => self.transfers.finish_download(id, Err(error)),
                }
            }
        }
    }
    fn progress(&self, id: u64) -> impl FnMut(u64, u64) + Send + 'static {
        let sender = self.sender.clone();
        move |done, total| { let _ = sender.send(Event::Progress { id, done, total }); }
    }
    fn uploader(&self, start: Start, source: Option<PathBuf>) -> impl FnOnce() -> Event + Send + 'static {
        let (api, mut progress) = (self.api.clone(), self.progress(start.id));
        move || {
            let result = source
                .ok_or_else(|| FileError::Local(std::io::Error::new(std::io::ErrorKind::NotFound, "the file to send is no longer listed")))
                .and_then(|path| std::fs::File::open(path).map_err(FileError::Local))
                .and_then(|mut file| api.upload(&start.name, &mut file, start.size, &mut progress, &start.cancel));
            Event::Uploaded { id: start.id, result }
        }
    }
    fn downloader(&self, start: Start, dest: PathBuf) -> impl FnOnce() -> Event + Send + 'static {
        let (api, mut progress) = (self.api.clone(), self.progress(start.id));
        move || {
            // Its name was free when it was queued; a file that took it since is not replaced.
            let result = if dest.exists() {
                Err(FileError::Local(std::io::Error::new(std::io::ErrorKind::AlreadyExists, format!("{} already exists", dest.display()))))
            } else {
                api.download(&start.name, start.size, &dest, &mut progress, &start.cancel)
            };
            Event::Downloaded { id: start.id, result }
        }
    }
    fn poll(&mut self) {
        while let Ok(event) = self.events.try_recv() {
            self.handle(event);
        }
    }
    fn handle(&mut self, event: Event) {
        match event {
            Event::Access(Ok((upload, download))) => {
                self.access = Access::Known { upload, download };
                // A device that may only send still learns the folder, its free space and limit.
                if upload.is_supported() || download.is_supported() {
                    self.read_folder();
                } else {
                    self.list = None;
                }
            }
            Event::Access(Err(e)) => self.access = Access::Failed(e.to_string()),
            Event::Listed { ask, result } => {
                if self.listing != Some(ask) {
                    return;
                }
                self.listing = None;
                self.list = Some(result.map_err(|e| (Problem::of(&e).unwrap_or(Problem::Host), e.to_string())));
            }
            Event::Progress { id, done, total } => {
                self.transfers.progress(id, done, total);
            }
            Event::Uploaded { id, result } => {
                self.transfers.finish_upload(id, result);
                if self.transfers.uploaded_since(&[id]) {
                    self.read_folder();
                }
                self.pump();
            }
            Event::Downloaded { id, result } => {
                self.transfers.finish_download(id, result);
                self.pump();
            }
        }
    }
    fn snapshot(&mut self) -> Value {
        self.poll();
        let (access, may_upload, may_download, upload_refusal, download_refusal, access_error) = match &self.access {
            Access::Checking => ("checking", false, false, None, None, None),
            Access::Failed(e) => ("failed", false, false, None, None, Some(e.clone())),
            Access::Known { upload, download } => ("known", upload.is_supported(), download.is_supported(), refusal_text(*upload, true), refusal_text(*download, false), None),
        };
        let (list, list_error) = match &self.list {
            Some(Ok(list)) => (json!({"folder":list.folder,"freeBytes":list.free_bytes,"maxFileBytes":list.max_file_bytes,
                "files":list.files.iter().map(|f| json!({"name":f.name,"size":f.size,"modifiedMs":f.modified_unix_ms})).collect::<Vec<_>>()}), None),
            Some(Err((problem, _))) => (Value::Null, Some(problem_text(*problem))),
            None => (Value::Null, None),
        };
        let folder = self.folder.clone();
        json!({"access":access,"mayUpload":may_upload,"mayDownload":may_download,"uploadRefusal":upload_refusal,"downloadRefusal":download_refusal,
            "accessError":access_error,"list":list,"listError":list_error,"listing":self.listing.is_some(),
            "active":self.transfers.is_active(),"downloads":folder.display().to_string(),"notices":std::mem::take(&mut self.notices),
            "transfers":self.transfers.items().iter().map(|t| json!({"id":t.id,"upload":t.direction == Direction::Upload,"title":title(t),
                "status":status(t, &folder),"fraction":t.fraction(),"finished":t.state.is_finished(),"cancelling":t.is_cancelling(),
                "failed":matches!(t.state, State::Failed { .. }),"canRetry":t.can_retry(),
                "savedName":match (&t.state, t.direction) { (State::Done { name, .. }, Direction::Download) => Some(name.clone()), _ => None },
                "detail":match &t.state { State::Failed { message, .. } => Some(message.clone()), _ => None }})).collect::<Vec<_>>()})
    }
    fn request(&mut self, operation: &str, v: &Value) -> Result<Value, String> {
        self.poll();
        let id = || v["id"].as_u64().ok_or("missing id");
        match operation {
            "snapshot" => {}
            "checkAgain" => self.check_again(),
            "refresh" => self.read_folder(),
            "send" => self.send(v["paths"].as_array().ok_or("missing paths")?.iter().filter_map(Value::as_str).map(PathBuf::from).collect()),
            "download" => self.download(v["name"].as_str().ok_or("missing name")?, v["size"].as_u64().ok_or("missing size")?),
            "cancel" => { self.transfers.cancel(id()?); self.pump(); }
            "retry" => { self.transfers.retry(id()?); self.pump(); }
            "clearFinished" => {
                self.transfers.clear_finished();
                let transfers = &self.transfers;
                self.sources.retain(|id, _| transfers.get(*id).is_some());
            }
            _ => return Err("unknown files operation".into()),
        }
        Ok(self.snapshot())
    }
}
/// `name`, or `name (2)`, `name (3)`, ... before its extension: the first free one.
fn free_name(folder: &Path, name: &str, taken: &[&str]) -> String {
    let (stem, extension) = match name.rfind('.') {
        Some(dot) if dot > 0 => name.split_at(dot),
        _ => (name, ""),
    };
    let free = |candidate: &str| {
        let path = folder.join(candidate);
        !taken.iter().any(|t| t.eq_ignore_ascii_case(candidate)) && !path.exists() && !partial_path(&path).exists()
    };
    if free(name) {
        return name.to_owned();
    }
    (2..).map(|n| format!("{stem} ({n}){extension}")).find(|candidate| free(candidate)).expect("some number is free")
}
/// A size in the units Finder shows.
fn size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "kB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 { format!("{bytes} B") } else { format!("{value:.1} {}", UNITS[unit]) }
}
fn problem_text(problem: Problem) -> &'static str {
    match problem {
        Problem::NoPermission => "This Mac lacks the permission; allow it in the PC's web UI, under Devices.",
        Problem::TransferOff => "File transfer is off on the PC; turn it on in its web UI.",
        Problem::InvalidName => "The PC refused the file name.",
        Problem::Interrupted => "The upload stopped before its end.",
        Problem::TooLarge => "The file is larger than the PC allows.",
        Problem::NoSpace => "The PC does not have enough free space.",
        Problem::NoConsoleUser => "Nobody is signed in on the PC.",
        Problem::Busy => "The PC is busy with other transfers; try again shortly.",
        Problem::NotFound => "The file is no longer on the PC.",
        Problem::Network => "The connection to the PC failed.",
        Problem::Local => "The file on this Mac could not be read or written.",
        Problem::Host => "The PC answered with an error.",
    }
}
fn refusal_text(availability: Availability, upload: bool) -> Option<&'static str> {
    match availability {
        Availability::Supported => None,
        Availability::Unsupported(Some(Reason::FilePermission)) if upload => Some("This Mac may not send files to this PC. On the PC, open the web UI's Devices page and allow Upload files for it."),
        Availability::Unsupported(Some(Reason::FilePermission)) => Some("This Mac may not download this PC's files. On the PC, open the web UI's Devices page and allow Download files for it."),
        Availability::Unsupported(None) if upload => Some("This PC takes no files."),
        Availability::Unsupported(None) => Some("This PC offers no files to download."),
        Availability::Unsupported(Some(_)) => Some("This PC's host has no file transfer."),
        Availability::Unknown => Some("The PC is not online."),
    }
}
fn status(transfer: &Transfer, folder: &Path) -> String {
    let upload = transfer.direction == Direction::Upload;
    let verb = if upload { "Sending" } else { "Downloading" };
    match &transfer.state {
        State::Queued => "Waiting".into(),
        State::Running { .. } if transfer.is_cancelling() => "Canceling…".into(),
        State::Running { done, total } if *total > 0 => format!("{verb} · {} % ({} of {})", (transfer.fraction().unwrap_or(0.0) * 100.0) as u32, size(*done), size(*total)),
        State::Running { done, .. } => format!("{verb} · {}", size(*done)),
        State::Done { name, .. } if upload && *name == transfer.name => "Sent".into(),
        State::Done { name, .. } if upload => format!("Sent as {name}"),
        State::Done { name, .. } => format!("Saved to {}", folder.join(name).display()),
        State::Failed { problem, .. } => problem_text(*problem).into(),
        State::Cancelled => "Canceled".into(),
    }
}
fn title(transfer: &Transfer) -> String {
    match transfer.direction {
        _ if transfer.name == transfer.local_name => transfer.name.clone(),
        Direction::Upload => format!("{} → {}", transfer.local_name, transfer.name),
        Direction::Download => format!("{} → {}", transfer.name, transfer.local_name),
    }
}

pub struct MysticFiles(Mutex<Page>);
/// Opens a host's Files page, which asks the PC at once. Downloads land in `downloads`.
#[no_mangle]
pub unsafe extern "C" fn mystic_files_new(host: *const MysticHost, downloads: *const c_char) -> *mut MysticFiles {
    let (Some(host), false) = (host.as_ref(), downloads.is_null()) else { return std::ptr::null_mut() };
    let Ok(folder) = CStr::from_ptr(downloads).to_str() else { return std::ptr::null_mut() };
    Box::into_raw(Box::new(MysticFiles(Mutex::new(Page::new(host.client.clone(), PathBuf::from(folder))))))
}
/// `snapshot`, `checkAgain`, `refresh`, `send` {paths}, `download` {name,size}, `cancel` {id},
/// `retry` {id} or `clearFinished`; each answers with the page's snapshot. Never blocks on the PC.
#[no_mangle]
pub unsafe extern "C" fn mystic_files_request(files: *const MysticFiles, operation: *const c_char, request: *const c_char) -> *mut c_char {
    envelope_for((|| {
        let files = files.as_ref().ok_or("null files")?;
        if operation.is_null() || request.is_null() { return Err("null request".to_owned()); }
        let operation = CStr::from_ptr(operation).to_str().map_err(|_| "invalid UTF-8")?;
        let request: Value = serde_json::from_str(CStr::from_ptr(request).to_str().map_err(|_| "invalid UTF-8")?).map_err(|_| "invalid request JSON")?;
        files.0.lock().unwrap_or_else(|e| e.into_inner()).request(operation, &request)
    })())
}
/// Cancels every transfer that has not finished.
#[no_mangle]
pub unsafe extern "C" fn mystic_files_free(files: *mut MysticFiles) {
    if !files.is_null() {
        drop(Box::from_raw(files));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::time::{Duration, Instant};

    struct Fake { listed: Vec<(String, u64)> }
    impl FileHost for Fake {
        fn access(&self) -> Result<(Availability, Availability), Error> { Ok((Availability::Supported, Availability::Supported)) }
        fn list(&self) -> Result<FileList, FileError> {
            Ok(FileList { folder: "C:\\Transfer".into(), free_bytes: 5000, max_file_bytes: 9000,
                files: self.listed.iter().map(|(name, size)| nightjar_core::http::RemoteFile { name: name.clone(), size: *size, modified_unix_ms: 1 }).collect() })
        }
        fn upload(&self, name: &str, file: &mut dyn Read, length: u64, progress: &mut dyn FnMut(u64, u64), _: &TransferCancel) -> Result<Uploaded, FileError> {
            let mut body = Vec::new();
            file.read_to_end(&mut body).map_err(FileError::Local)?;
            progress(length, length);
            Ok(Uploaded { name: name.into(), size: body.len() as u64 })
        }
        fn download(&self, _: &str, listed: u64, dest: &Path, progress: &mut dyn FnMut(u64, u64), _: &TransferCancel) -> Result<u64, FileError> {
            std::fs::File::create(dest).and_then(|mut f| f.write_all(&vec![7; listed as usize])).map_err(FileError::Local)?;
            progress(listed, listed);
            Ok(listed)
        }
    }
    fn folder(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("mystic-files-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    fn until(page: &mut Page, done: impl Fn(&Value) -> bool) -> Value {
        let start = Instant::now();
        loop {
            let snapshot = page.snapshot();
            if done(&snapshot) { return snapshot; }
            assert!(start.elapsed() < Duration::from_secs(5), "{snapshot}");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn a_page_asks_then_lists_and_moves_files_both_ways() {
        let downloads = folder("both");
        let source = downloads.join("note.txt");
        std::fs::write(&source, b"hello").unwrap();
        let mut page = Page::new(Arc::new(Fake { listed: vec![("note.txt".into(), 3)] }), downloads.clone());
        let listed = until(&mut page, |s| !s["list"].is_null());
        assert_eq!(listed["mayUpload"], true);
        assert_eq!(listed["list"]["files"][0]["name"], "note.txt");
        page.request("send", &json!({"paths":[source, downloads.join("missing")]})).unwrap();
        // The download finds its name taken by the file sent, so it lands beside it.
        page.request("download", &json!({"name":"note.txt","size":3})).unwrap();
        let done = until(&mut page, |s| s["active"] == false && s["transfers"].as_array().is_some_and(|t| t.len() == 2));
        assert_eq!(done["transfers"][0]["status"], "Sent");
        assert_eq!(done["transfers"][1]["savedName"], "note (2).txt");
        assert_eq!(std::fs::read(downloads.join("note (2).txt")).unwrap(), vec![7; 3]);
        page.request("clearFinished", &json!({})).unwrap();
        assert!(page.snapshot()["transfers"].as_array().unwrap().is_empty());
    }
    #[test]
    fn a_file_that_cannot_be_read_says_so_and_a_folder_is_not_sent() {
        let downloads = folder("missing");
        let mut page = Page::new(Arc::new(Fake { listed: vec![] }), downloads.clone());
        let answer = page.request("send", &json!({"paths":[&downloads, downloads.join("gone")]})).unwrap();
        let notices = answer["notices"].as_array().unwrap();
        assert!(notices[0].as_str().unwrap().ends_with("it is not a file."));
        assert!(notices[1].as_str().unwrap().contains("gone was not sent"));
        assert!(answer["transfers"].as_array().unwrap().is_empty());
        // A snapshot gives each notice once.
        assert!(page.snapshot()["notices"].as_array().unwrap().is_empty());
    }
    #[test]
    fn names_avoid_files_partials_and_other_downloads() {
        let downloads = folder("names");
        std::fs::write(downloads.join("a.txt"), b"").unwrap();
        std::fs::write(partial_path(&downloads.join("a (2).txt")), b"").unwrap();
        assert_eq!(free_name(&downloads, "a.txt", &["A (3).TXT"]), "a (4).txt");
        assert_eq!(free_name(&downloads, "b", &[]), "b");
    }
    #[test]
    fn every_problem_and_refusal_has_words_and_sizes_read_well() {
        for problem in Problem::ALL { assert!(!problem_text(problem).is_empty()); }
        assert!(refusal_text(Availability::Supported, true).is_none());
        assert!(refusal_text(Availability::Unsupported(Some(Reason::FilePermission)), true).unwrap().contains("Upload files"));
        assert_eq!(size(999), "999 B");
        assert_eq!(size(1_500_000), "1.5 MB");
    }
    #[test]
    fn null_handles_are_refused() {
        unsafe {
            assert!(mystic_files_new(std::ptr::null(), std::ptr::null()).is_null());
            mystic_files_free(std::ptr::null_mut());
        }
    }
}
