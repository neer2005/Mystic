//! The folders a PC shares with this device, without their drawing: Nightjar's `folders_page.rs`.
//! The folders, their directories, a file downloaded into a folder chosen here, and a file
//! uploaded into a directory with a write grant. One request and one transfer at a time, each on
//! a thread; the app polls a snapshot. Freeing the page cancels the transfer. Requests still in
//! flight end by themselves: this client is shared with the host's other calls, which Nightjar's
//! cancel would end for good.
use crate::host::{envelope_for, MysticHost};
use nightjar_core::http::{child_path, parent_path, Availability, EntryKind, Error, Feature, FileError, FileRefusal, FolderEntries, HostClient, Reason, SharedFolder, TransferCancel, Uploaded};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

trait FolderSource: Send + Sync + 'static {
    fn access(&self) -> Result<Availability, Error>;
    fn folders(&self) -> Result<Vec<SharedFolder>, FileError>;
    fn entries(&self, id: &str, path: &str) -> Result<FolderEntries, FileError>;
    fn save(&self, id: &str, path: &str, listed: u64, dir: &Path, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<PathBuf, FileError>;
    fn upload(&self, id: &str, path: &str, file: &mut dyn std::io::Read, length: u64, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<Uploaded, FileError>;
}
impl FolderSource for HostClient {
    fn access(&self) -> Result<Availability, Error> {
        let capabilities = self.server_info_https()?.capabilities.with_native(&self.native_capabilities_with_files()?);
        Ok(capabilities.availability(Feature::SharedFolders))
    }
    fn folders(&self) -> Result<Vec<SharedFolder>, FileError> { self.shared_folders() }
    fn entries(&self, id: &str, path: &str) -> Result<FolderEntries, FileError> { self.folder_entries(id, path) }
    fn save(&self, id: &str, path: &str, listed: u64, dir: &Path, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<PathBuf, FileError> {
        self.save_folder_file(id, path, listed, dir, progress, stop)
    }
    fn upload(&self, id: &str, path: &str, file: &mut dyn std::io::Read, length: u64, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<Uploaded, FileError> {
        self.upload_folder_file(id, path, file, length, progress, stop)
    }
}
#[derive(Clone, Debug, PartialEq)]
enum Place {
    Folders,
    Dir { folder: SharedFolder, path: String },
}
#[derive(Default)]
struct Progress { done: AtomicU64, total: AtomicU64 }
struct Transfer { upload: bool, name: String, progress: Arc<Progress>, stop: Arc<TransferCancel> }
enum Answer {
    Access(u64, Result<Availability, Error>),
    Folders(u64, Result<Vec<SharedFolder>, FileError>),
    Entries(u64, Result<FolderEntries, FileError>),
    /// A finished transfer: what to say, and whether the directory changed.
    Done(Result<String, FileError>, bool),
}
struct Page {
    source: Arc<dyn FolderSource>,
    refusal: Option<&'static str>,
    place: Place,
    folders: Vec<SharedFolder>,
    entries: Option<FolderEntries>,
    loading: bool,
    ask: u64,
    transfer: Option<Transfer>,
    error: Option<String>,
    transfer_error: Option<String>,
    done: Option<String>,
    answers: Receiver<Answer>,
    sender: Sender<Answer>,
}
impl Drop for Page {
    fn drop(&mut self) {
        if let Some(transfer) = &self.transfer { transfer.stop.cancel(); }
    }
}
fn spawn(name: &str, work: impl FnOnce() + Send + 'static) -> Result<(), String> {
    std::thread::Builder::new().name(name.into()).spawn(work).map(drop).map_err(|e| format!("Could not start the request: {e}"))
}
impl Page {
    fn new(source: Arc<dyn FolderSource>) -> Self {
        let (sender, answers) = channel();
        let mut page = Self { source, refusal: None, place: Place::Folders, folders: Vec::new(), entries: None, loading: false, ask: 0,
            transfer: None, error: None, transfer_error: None, done: None, answers, sender };
        page.begin(true);
        page
    }
    fn begin(&mut self, check: bool) {
        self.ask += 1;
        self.loading = true;
        self.error = None;
        let (ask, source, sender, place) = (self.ask, self.source.clone(), self.sender.clone(), self.place.clone());
        let started = spawn("shared folders", move || {
            let answer = match place {
                Place::Folders if check => Answer::Access(ask, source.access()),
                Place::Folders => Answer::Folders(ask, source.folders()),
                Place::Dir { folder, path } => Answer::Entries(ask, source.entries(&folder.id, &path)),
            };
            let _ = sender.send(answer);
        });
        if let Err(e) = started {
            self.loading = false;
            self.error = Some(e);
        }
    }
    fn go(&mut self, place: Place) {
        self.place = place;
        self.entries = None;
        self.done = None;
        self.transfer_error = None;
        self.begin(false);
    }
    fn up(&mut self) {
        match self.place.clone() {
            Place::Folders => {}
            Place::Dir { path, .. } if path.is_empty() => self.go(Place::Folders),
            Place::Dir { folder, path } => self.go(Place::Dir { path: parent_path(&path).to_owned(), folder }),
        }
    }
    fn refuse_second(&mut self) -> bool {
        if self.transfer.is_none() { return false; }
        self.done = None;
        self.transfer_error = Some("Another transfer is still running.".into());
        true
    }
    fn start(&mut self, upload: bool, name: String, job: Box<Job>) {
        let transfer = Transfer { upload, name, progress: Arc::default(), stop: Arc::new(TransferCancel::new()) };
        let (source, sender, progress, stop) = (self.source.clone(), self.sender.clone(), transfer.progress.clone(), transfer.stop.clone());
        self.transfer_error = None;
        self.done = None;
        self.transfer = Some(transfer);
        let started = spawn("shared folder transfer", move || {
            let mut report = |done, total| {
                progress.done.store(done, Ordering::Relaxed);
                progress.total.store(total, Ordering::Relaxed);
            };
            let (said, changed) = match job(source.as_ref(), &mut report, &stop) {
                Ok((said, changed)) => (Ok(said), changed),
                Err(e) => (Err(e), false),
            };
            let _ = sender.send(Answer::Done(said, changed));
        });
        if let Err(e) = started {
            self.transfer = None;
            self.transfer_error = Some(e);
        }
    }
    fn download(&mut self, name: &str, size: u64, dir: PathBuf) {
        // Only a directory lists files to pick.
        let Place::Dir { folder, path } = self.place.clone() else { return };
        if self.refuse_second() { return; }
        let remote = child_path(&path, name);
        self.start(false, name.to_owned(), Box::new(move |source, progress, stop| {
            source.save(&folder.id, &remote, size, &dir, progress, stop).map(|saved| (format!("Saved to {}", saved.display()), false))
        }));
    }
    fn upload(&mut self, local: PathBuf) {
        let Place::Dir { folder, path } = self.place.clone() else { return };
        if !folder.writable() || self.refuse_second() { return; }
        let Some(name) = local.file_name().and_then(|n| n.to_str()).map(str::to_owned) else {
            self.done = None;
            self.transfer_error = Some(format!("The PC takes only file names in Unicode: {}", local.display()));
            return;
        };
        let remote = child_path(&path, &name);
        self.start(true, name, Box::new(move |source, progress, stop| {
            let mut file = std::fs::File::open(&local).map_err(FileError::Local)?;
            let length = file.metadata().map_err(FileError::Local)?.len();
            source.upload(&folder.id, &remote, &mut file, length, progress, stop).map(|up| (format!("Uploaded as {}", up.name), true))
        }));
    }
    fn poll(&mut self) {
        let mut relist = false;
        while let Ok(answer) = self.answers.try_recv() {
            match answer {
                Answer::Access(ask, _) | Answer::Folders(ask, _) | Answer::Entries(ask, _) if ask != self.ask => {}
                Answer::Access(_, Ok(availability)) => {
                    self.refusal = refusal_text(availability);
                    if self.refusal.is_none() { self.begin(false); } else { self.loading = false; }
                }
                Answer::Access(_, Err(e)) => {
                    self.loading = false;
                    self.error = Some(e.to_string());
                }
                Answer::Folders(_, result) => {
                    self.loading = false;
                    match result {
                        Ok(folders) => self.folders = folders,
                        Err(e) => self.error = Some(folder_error(&e)),
                    }
                }
                Answer::Entries(_, result) => {
                    self.loading = false;
                    match result {
                        Ok(entries) => self.entries = Some(entries),
                        Err(e) => self.error = Some(folder_error(&e)),
                    }
                }
                Answer::Done(result, changed) => {
                    self.transfer = None;
                    match result {
                        Ok(said) => {
                            self.done = Some(said);
                            self.transfer_error = None;
                            relist |= changed;
                        }
                        Err(e) => self.transfer_error = Some(folder_error(&e)),
                    }
                }
            }
        }
        if relist { self.begin(false); }
    }
    fn snapshot(&mut self) -> Value {
        self.poll();
        let (folder, path) = match &self.place {
            Place::Folders => (Value::Null, String::new()),
            Place::Dir { folder, path } => (json!({"id":folder.id,"name":folder.name,"writable":folder.writable()}), path.clone()),
        };
        json!({"refusal":self.refusal,"folder":folder,"path":path,"loading":self.loading,"error":self.error,
            "transferError":self.transfer_error,"done":self.done,
            "folders":self.folders.iter().map(|f| json!({"id":f.id,"name":f.name,"writable":f.writable()})).collect::<Vec<_>>(),
            "entries":self.entries.as_ref().map(|listing| listing.entries.iter().filter(|e| e.kind != EntryKind::Unknown)
                .map(|e| json!({"name":e.name,"directory":e.kind == EntryKind::Dir,"size":e.size,"modifiedMs":e.modified_unix_ms})).collect::<Vec<_>>()),
            "transfer":self.transfer.as_ref().map(|t| json!({"upload":t.upload,"name":t.name,
                "done":t.progress.done.load(Ordering::Relaxed),"total":t.progress.total.load(Ordering::Relaxed)}))})
    }
    fn request(&mut self, operation: &str, v: &Value) -> Result<Value, String> {
        self.poll();
        let text = |key: &str| v[key].as_str().map(str::to_owned).ok_or(format!("missing {key}"));
        match operation {
            "snapshot" => {}
            "list" => { let check = self.place == Place::Folders && self.refusal.is_some(); self.begin(check); }
            "up" => self.up(),
            "enterFolder" => {
                let id = text("id")?;
                let folder = self.folders.iter().find(|f| f.id == id).cloned().ok_or("no such folder")?;
                self.go(Place::Dir { folder, path: String::new() });
            }
            "enterDir" => {
                let Place::Dir { folder, path } = self.place.clone() else { return Err("not in a folder".into()) };
                self.go(Place::Dir { folder, path: child_path(&path, &text("name")?) });
            }
            "download" => self.download(&text("name")?, v["size"].as_u64().ok_or("missing size")?, PathBuf::from(text("into")?)),
            "upload" => self.upload(PathBuf::from(text("path")?)),
            "cancel" => { if let Some(transfer) = &self.transfer { transfer.stop.cancel(); } }
            _ => return Err("unknown folders operation".into()),
        }
        Ok(self.snapshot())
    }
}
type Job = dyn FnOnce(&dyn FolderSource, &mut dyn FnMut(u64, u64), &TransferCancel) -> Result<(String, bool), FileError> + Send;
fn refusal_text(availability: Availability) -> Option<&'static str> {
    match availability {
        Availability::Supported => None,
        Availability::Unsupported(Some(Reason::FolderPermission)) => Some("This Mac may not open this PC's shared folders. On the PC, open the web UI's Devices page and allow Shared folders for it."),
        Availability::Unsupported(None) => Some("The PC shares no folders. Choose folders to share in its web UI."),
        Availability::Unsupported(Some(_)) => Some("This PC's host has no shared folders."),
        Availability::Unknown => Some("The PC is not online."),
    }
}
fn folder_error(error: &FileError) -> String {
    let why = match error {
        FileError::Refused { refusal, .. } => match refusal {
            FileRefusal::Forbidden => Some("This Mac has no grant for this folder, or may only read it."),
            FileRefusal::FoldersDisabled => Some("The PC shares no folders."),
            FileRefusal::FolderUnreadable => Some("The PC can't read this folder: Windows denies its signed-in user access. Check the folder's permissions on the PC."),
            FileRefusal::NoConsoleUser => Some("Nobody is signed in on the PC. Shared folders open as the signed-in Windows user."),
            FileRefusal::NotFound => Some("The file or folder is no longer there."),
            FileRefusal::TooLarge => Some("The file is larger than the PC takes."),
            FileRefusal::InsufficientStorage => Some("The PC's drive is full."),
            FileRefusal::TransferBusy => Some("Another upload from this Mac is still running."),
            FileRefusal::InvalidName => Some("The PC does not take this name."),
            _ => None,
        },
        FileError::Local(_) => Some("The file on this Mac could not be read or written."),
        FileError::Host(Error::Cancelled) => return "Transfer cancelled.".into(),
        FileError::Host(_) => None,
    };
    match why {
        Some(why) => format!("{why}\n{error}"),
        None => error.to_string(),
    }
}

pub struct MysticFolders(Mutex<Page>);
#[no_mangle]
pub unsafe extern "C" fn mystic_folders_new(host: *const MysticHost) -> *mut MysticFolders {
    let Some(host) = host.as_ref() else { return std::ptr::null_mut() };
    Box::into_raw(Box::new(MysticFolders(Mutex::new(Page::new(host.client.clone())))))
}
/// `snapshot`, `list`, `up`, `enterFolder` {id}, `enterDir` {name}, `download` {name,size,into},
/// `upload` {path} or `cancel`; each answers with the page's snapshot. Never blocks on the PC.
#[no_mangle]
pub unsafe extern "C" fn mystic_folders_request(folders: *const MysticFolders, operation: *const c_char, request: *const c_char) -> *mut c_char {
    envelope_for((|| {
        let folders = folders.as_ref().ok_or("null folders")?;
        if operation.is_null() || request.is_null() { return Err("null request".to_owned()); }
        let operation = CStr::from_ptr(operation).to_str().map_err(|_| "invalid UTF-8")?;
        let request: Value = serde_json::from_str(CStr::from_ptr(request).to_str().map_err(|_| "invalid UTF-8")?).map_err(|_| "invalid request JSON")?;
        folders.0.lock().unwrap_or_else(|e| e.into_inner()).request(operation, &request)
    })())
}
#[no_mangle]
pub unsafe extern "C" fn mystic_folders_free(folders: *mut MysticFolders) {
    if !folders.is_null() { drop(Box::from_raw(folders)); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nightjar_core::http::{FolderAccess, FolderEntry};
    use std::time::{Duration, Instant};

    struct Fake { availability: Availability, slow: bool }
    impl FolderSource for Fake {
        fn access(&self) -> Result<Availability, Error> { Ok(self.availability) }
        fn folders(&self) -> Result<Vec<SharedFolder>, FileError> {
            Ok(vec![SharedFolder { id: "g".into(), name: "Games".into(), access: FolderAccess::Read }, SharedFolder { id: "m".into(), name: "Music".into(), access: FolderAccess::Write }])
        }
        fn entries(&self, _: &str, path: &str) -> Result<FolderEntries, FileError> {
            let entry = |name: &str, kind| FolderEntry { name: name.into(), kind, size: 3, modified_unix_ms: 1 };
            Ok(FolderEntries { path: path.into(), entries: vec![entry("sub", EntryKind::Dir), entry("a.txt", EntryKind::File), entry("odd", EntryKind::Unknown)] })
        }
        fn save(&self, _: &str, path: &str, _: u64, dir: &Path, progress: &mut dyn FnMut(u64, u64), stop: &TransferCancel) -> Result<PathBuf, FileError> {
            progress(1, 3);
            while self.slow && !stop.is_cancelled() { std::thread::sleep(Duration::from_millis(1)); }
            if stop.is_cancelled() { return Err(FileError::Host(Error::Cancelled)); }
            Ok(dir.join(path))
        }
        fn upload(&self, _: &str, path: &str, file: &mut dyn std::io::Read, length: u64, _: &mut dyn FnMut(u64, u64), _: &TransferCancel) -> Result<Uploaded, FileError> {
            let mut body = Vec::new();
            file.read_to_end(&mut body).map_err(FileError::Local)?;
            assert_eq!(body.len() as u64, length);
            Ok(Uploaded { name: path.into(), size: length })
        }
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
    fn open(slow: bool) -> Page {
        let mut page = Page::new(Arc::new(Fake { availability: Availability::Supported, slow }));
        until(&mut page, |s| s["folders"].as_array().is_some_and(|f| f.len() == 2));
        page
    }
    #[test]
    fn browsing_goes_down_and_back_up_and_hides_unknown_kinds() {
        let mut page = open(false);
        page.request("enterFolder", &json!({"id":"g"})).unwrap();
        let top = until(&mut page, |s| !s["entries"].is_null());
        assert_eq!(top["folder"]["name"], "Games");
        assert_eq!(top["entries"].as_array().unwrap().len(), 2);
        page.request("enterDir", &json!({"name":"sub"})).unwrap();
        assert_eq!(until(&mut page, |s| !s["entries"].is_null())["path"], "sub");
        page.request("up", &json!({})).unwrap();
        assert_eq!(until(&mut page, |s| !s["entries"].is_null())["path"], "");
        page.request("up", &json!({})).unwrap();
        assert!(page.snapshot()["folder"].is_null());
    }
    #[test]
    fn a_read_only_folder_takes_no_upload_and_a_writable_one_relists() {
        let file = std::env::temp_dir().join(format!("mystic-folders-{}.txt", std::process::id()));
        std::fs::write(&file, b"abc").unwrap();
        let mut page = open(false);
        page.request("enterFolder", &json!({"id":"g"})).unwrap();
        until(&mut page, |s| !s["entries"].is_null());
        assert!(page.request("upload", &json!({"path":&file})).unwrap()["transfer"].is_null());
        page.request("up", &json!({})).unwrap();
        until(&mut page, |s| s["loading"] == false);
        page.request("enterFolder", &json!({"id":"m"})).unwrap();
        until(&mut page, |s| !s["entries"].is_null());
        page.request("upload", &json!({"path":&file})).unwrap();
        let done = until(&mut page, |s| s["transfer"].is_null() && s["loading"] == false);
        assert!(done["done"].as_str().unwrap().starts_with("Uploaded as"));
        let _ = std::fs::remove_file(file);
    }
    #[test]
    fn one_transfer_at_a_time_and_cancel_says_so() {
        let mut page = open(true);
        page.request("enterFolder", &json!({"id":"g"})).unwrap();
        until(&mut page, |s| !s["entries"].is_null());
        let first = page.request("download", &json!({"name":"a.txt","size":3,"into":"/tmp"})).unwrap();
        assert_eq!(first["transfer"]["name"], "a.txt");
        let second = page.request("download", &json!({"name":"a.txt","size":3,"into":"/tmp"})).unwrap();
        assert_eq!(second["transferError"], "Another transfer is still running.");
        page.request("cancel", &json!({})).unwrap();
        let ended = until(&mut page, |s| s["transfer"].is_null());
        assert_eq!(ended["transferError"], "Transfer cancelled.");
    }
    #[test]
    fn a_refused_device_hears_why_and_lists_nothing() {
        let mut page = Page::new(Arc::new(Fake { availability: Availability::Unsupported(Some(Reason::FolderPermission)), slow: false }));
        let snapshot = until(&mut page, |s| !s["refusal"].is_null());
        assert!(snapshot["refusal"].as_str().unwrap().contains("Devices page"));
        assert!(snapshot["folders"].as_array().unwrap().is_empty());
    }
}
