//! The notebook window: commands the page calls, and the snagbook: scheme that serves an
//! item's pictures and videos to the editor.

mod capture;
mod markup;
mod media;
mod record;

use base64::Engine;
use chrono::Utc;
use serde::Serialize;
use snagbook_core::{Config, ConfigStore, FolderIdentity, HandoffStyle, Paths, Session, Shortcuts, SnagError, Summary, Template};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindowBuilder};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tauri_plugin_opener::OpenerExt;

pub struct App {
    pub store: ConfigStore,
    pub session: Option<Session>,
    /// The item the page shows: where a screenshot goes.
    pub selected: Option<i64>,
    /// Global shortcuts that could not be registered, in words.
    pub shortcut_errors: Vec<String>,
    origins: HashMap<String, SessionOrigin>,
    item_origins: HashMap<FolderIdentity, String>,
}

#[derive(Clone)]
struct SessionOrigin {
    session: PathBuf,
    display_path: String,
    session_identity: FolderIdentity,
    session_id: String,
}

type St<'a> = State<'a, Mutex<App>>;
type Res<T> = Result<T, String>;

fn err(e: SnagError) -> String {
    e.to_string()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemView {
    id: i64,
    item_token: String,
    title: String,
    folder: String,
    images: usize,
    videos: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    id: String,
    open_token: String,
    path: String,
    title: String,
    /// This session's own header, or None when it follows the global one.
    header: Option<String>,
    items: Vec<ItemView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    config: Config,
    session: Option<SessionView>,
    load_error: Option<String>,
    /// Set when the open session's folder disappeared and it was closed.
    closed: Option<String>,
    platform: &'static str,
    shortcut_errors: Vec<String>,
    /// When the running recording started (milliseconds since 1970), if one is running.
    recording: Option<u64>,
}

fn platform() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

/// Where the settings live: SNAGBOOK_CONFIG, or the system's settings folder.
fn config_path() -> PathBuf {
    if let Ok(p) = std::env::var("SNAGBOOK_CONFIG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    dirs::config_dir().unwrap_or_else(|| PathBuf::from(Paths::home()).join(".config")).join("Snagbook").join("config.json")
}

impl App {
    fn load() -> App {
        let store = ConfigStore::new(&config_path());
        let session = store.config.last_session.as_deref().and_then(|p| Session::open(p, &store.config.header).ok());
        let mut app = App { store, session, selected: None, shortcut_errors: vec![], origins: HashMap::new(), item_origins: HashMap::new() };
        app.remember_current();
        app
    }

    /// The whole state the page draws from. A session whose folder was deleted from outside
    /// is closed here rather than written back into existence.
    fn view(&mut self) -> View {
        let mut closed = None;
        if self.session.as_ref().is_some_and(|s| !s.exists()) {
            closed = self.session.take().map(|s| s.display_path);
            let _ = self.store.update(|c| c.last_session = None);
        }
        let session = self.session.as_ref().map(|s| SessionView {
            id: s.manifest.id.clone(),
            open_token: s.open_token.clone(),
            path: s.display_path.clone(),
            title: s.title(),
            header: s.manifest.header.clone(),
            items: s
                .manifest
                .items
                .iter()
                .map(|r| {
                    let c = s.media_count(r.id);
                    let item_token = s.item_identity(r.id).ok().map(|identity| {
                        self.item_origins.entry(identity).or_insert_with(|| uuid::Uuid::new_v4().to_string()).clone()
                    }).unwrap_or_default();
                    ItemView { id: r.id, item_token, title: r.title.clone(), folder: r.folder.clone(), images: c.images, videos: c.videos }
                })
                .collect(),
        });
        View {
            config: self.store.config.clone(),
            session,
            load_error: self.store.load_error.clone(),
            closed,
            platform: platform(),
            shortcut_errors: self.shortcut_errors.clone(),
            recording: None,
        }
    }

    fn session(&mut self) -> Res<&mut Session> {
        self.session.as_mut().ok_or_else(|| "No session is open.".to_string())
    }

    fn use_session(&mut self, s: Session) {
        let path = s.display_path.clone();
        self.origins.insert(s.open_token.clone(), SessionOrigin {
            session: s.dir.clone(),
            display_path: s.display_path.clone(),
            session_identity: s.folder_identity(),
            session_id: s.manifest.id.clone(),
        });
        self.session = Some(s);
        let _ = self.store.update(|c| c.last_session = Some(path));
    }

    fn remember_current(&mut self) {
        let Some(s) = self.session.as_ref() else { return };
        self.origins.entry(s.open_token.clone()).or_insert_with(|| SessionOrigin {
            session: s.dir.clone(),
            display_path: s.display_path.clone(),
            session_identity: s.folder_identity(),
            session_id: s.manifest.id.clone(),
        });
    }
}

#[tauri::command]
fn state(app: AppHandle, st: St) -> View {
    let mut v = st.lock().unwrap().view();
    v.recording = app.state::<Recorder>().0.lock().unwrap().as_ref().map(|r| r.started_ms);
    v
}

#[tauri::command]
fn list_sessions(st: St) -> Vec<Summary> {
    let root = st.lock().unwrap().store.config.sessions_folder.clone();
    Session::list(&root)
}

/// A new session with its first item, like pressing New Session in the macOS app.
#[tauri::command]
fn new_session(st: St) -> Res<View> {
    let mut a = st.lock().unwrap();
    let cfg = a.store.config.clone();
    let mut s = Session::create_now(&cfg.sessions_folder, &cfg).map_err(err)?;
    s.add_item(None, Utc::now()).map_err(err)?;
    a.use_session(s);
    Ok(a.view())
}

#[tauri::command]
fn open_session(st: St, path: String) -> Res<View> {
    let mut a = st.lock().unwrap();
    let s = Session::open(&path, &a.store.config.header).map_err(err)?;
    a.use_session(s);
    Ok(a.view())
}

#[tauri::command]
async fn pick_session_folder(app: tauri::AppHandle, st: St<'_>) -> Res<Option<View>> {
    let start = Paths::path(&st.lock().unwrap().store.config.sessions_folder);
    let picked = app.dialog().file().set_directory(start).blocking_pick_folder();
    let Some(p) = picked.and_then(|p| p.into_path().ok()) else { return Ok(None) };
    let mut a = st.lock().unwrap();
    let s = Session::open(&p.to_string_lossy(), &a.store.config.header).map_err(err)?;
    a.use_session(s);
    Ok(Some(a.view()))
}

#[tauri::command]
fn add_item(st: St, title: Option<String>) -> Res<View> {
    let mut a = st.lock().unwrap();
    if a.session.is_none() {
        let cfg = a.store.config.clone();
        let s = Session::create_now(&cfg.sessions_folder, &cfg).map_err(err)?;
        a.use_session(s);
    }
    a.session()?.add_item(title.as_deref(), Utc::now()).map_err(err)?;
    Ok(a.view())
}

#[tauri::command]
fn rename_item(app: AppHandle, st: St, session_id: String, open_token: String, item_token: String, id: i64, title: String) -> Res<View> {
    let mut a = st.lock().unwrap();
    if a.session.as_ref().is_none_or(|s| s.manifest.id != session_id || s.open_token != open_token) {
        return Err("The open session changed, so the item was not renamed.".into());
    }
    let item_identity = a.item_origins.iter().find_map(|(identity, token)| (token == &item_token).then(|| identity.clone())).ok_or("The item is no longer known.")?;
    if a.session.as_ref().is_none_or(|s| !s.matches_item_identity(id, &item_identity)) {
        return Err("The item changed, so it was not renamed.".into());
    }
    // A recording is writing into this item's folder: the folder is renamed when it is done.
    let recording = app.state::<Busy>().has(a.session.as_ref().map(|s| s.dir.as_path()), id);
    let marking = app.state::<Markup>().0.lock().unwrap().as_ref().is_some_and(|p| a.session.as_ref().is_some_and(|s| p.session_id == s.manifest.id) && p.id == id);
    a.session()?.retitle_item(id, &title, !recording && !marking).map_err(err)?;
    Ok(a.view())
}

/// Move an item's folder to the Trash. When that is impossible the answer starts with
/// "NOTRASH:" and the page asks before calling again with `permanently`.
#[tauri::command]
fn delete_item(app: AppHandle, window: tauri::Window, st: St, session_id: String, open_token: String, item_token: String, id: i64, permanently: bool) -> Res<View> {
    if window.label() != "main" {
        return Err("Items are deleted from the notebook window.".into());
    }
    let mut a = st.lock().unwrap();
    if a.session.as_ref().is_none_or(|s| s.manifest.id != session_id || s.open_token != open_token) {
        return Err("The open session changed, so the item was not deleted.".into());
    }
    let item_identity = a.item_origins.iter().find_map(|(identity, token)| (token == &item_token).then(|| identity.clone())).ok_or("The item is no longer known.")?;
    if a.session.as_ref().is_none_or(|s| !s.matches_item_identity(id, &item_identity)) {
        return Err("The item changed, so it was not deleted.".into());
    }
    if app.state::<Busy>().has(a.session.as_ref().map(|s| s.dir.as_path()), id) {
        return Err("A capture is still being saved into this item. Delete it once the capture is in its note.".into());
    }
    if app.state::<Markup>().0.lock().unwrap().as_ref().is_some_and(|p| {
        a.session.as_ref().is_some_and(|s| p.session_id == s.manifest.id && s.matches_folder_identity(&p.session_identity)) && p.id == id
    }) {
        return Err("Finish or close the picture being marked up before deleting this item.".into());
    }
    let s = a.session()?;
    let r = if permanently {
        s.delete_item(id, |p| std::fs::remove_dir_all(p).map_err(Into::into))
    } else {
        let mut reason = String::new();
        let r = s.delete_item(id, |p| trash::delete(p).map_err(|e| {
            reason = e.to_string();
            SnagError::NoTrash
        }));
        if r == Err(SnagError::NoTrash) {
            return Err(format!("NOTRASH:{reason}"));
        }
        r
    };
    r.map_err(err)?;
    Ok(a.view())
}

#[tauri::command]
fn delete_session(app: AppHandle, window: tauri::Window, st: St, session_id: String, open_token: String, permanently: bool) -> Res<View> {
    if window.label() != "main" {
        return Err("Sessions are deleted from the notebook window.".into());
    }
    let mut a = st.lock().unwrap();
    let current = a.session.as_ref().ok_or_else(|| "No session is open.".to_string())?;
    if current.manifest.id != session_id || current.open_token != open_token {
        return Err("The open session changed, so it was not deleted.".into());
    }
    let dir = current.dir.clone();
    if app.state::<Busy>().has_session(&dir) {
        return Err("A capture is still being saved into this session. Delete it once the capture is in its note.".into());
    }
    if app.state::<Markup>().0.lock().unwrap().as_ref().is_some_and(|p| p.session_id == session_id) {
        return Err("Finish or close the picture being marked up before deleting this session.".into());
    }
    let r = if permanently {
        if !app.state::<SessionDeleteFallback>().0.lock().unwrap().remove(&(session_id.clone(), open_token.clone())) {
            return Err("Permanent deletion is available only after moving this session to the Trash has failed.".into());
        }
        a.session.as_ref().unwrap().delete(|p| std::fs::remove_dir_all(p).map_err(Into::into))
    } else {
        let mut reason = String::new();
        let r = a.session.as_ref().unwrap().delete(|p| {
            trash::delete(p).map_err(|e| {
                reason = e.to_string();
                SnagError::NoTrash
            })
        });
        if r == Err(SnagError::NoTrash) {
            app.state::<SessionDeleteFallback>().0.lock().unwrap().insert((session_id, open_token));
            return Err(format!("NOTRASH:{reason}"));
        }
        r
    };
    r.map_err(err)?;
    a.session = None;
    a.selected = None;
    let _ = a.store.update(|c| c.last_session = None);
    Ok(a.view())
}

#[tauri::command]
fn move_item(st: St, id: i64, index: usize) -> Res<View> {
    let mut a = st.lock().unwrap();
    a.session()?.move_item(id, index).map_err(err)?;
    Ok(a.view())
}

#[tauri::command]
fn read_note(st: St, session_id: String, open_token: String, item_token: String, id: i64) -> Res<String> {
    let mut a = st.lock().unwrap();
    if a.session.as_ref().is_none_or(|s| s.manifest.id != session_id || s.open_token != open_token) {
        return Err("The open session changed while the note was being read.".into());
    }
    let item_identity = a.item_origins.iter().find_map(|(identity, token)| (token == &item_token).then(|| identity.clone())).ok_or("The note's item is no longer known.")?;
    if a.session.as_ref().is_none_or(|s| !s.matches_item_identity(id, &item_identity)) {
        return Err("The note's item is gone or was replaced.".into());
    }
    let note = a.session()?.read_note(id).map_err(err)?;
    if a.session.as_ref().is_none_or(|s| !s.matches_item_identity(id, &item_identity)) {
        return Err("The note's item changed while it was being read.".into());
    }
    Ok(note)
}

#[tauri::command]
fn write_note(st: St, session_id: String, open_token: String, item_token: String, id: i64, markdown: String) -> Res<bool> {
    let mut a = st.lock().unwrap();
    if a.session.as_ref().is_none_or(|s| s.manifest.id != session_id || s.open_token != open_token) {
        return Err("The open session changed before the note could be saved.".into());
    }
    let item_identity = a.item_origins.iter().find_map(|(identity, token)| (token == &item_token).then(|| identity.clone())).ok_or("The note's item is no longer known.")?;
    if a.session.as_ref().is_none_or(|s| !s.matches_item_identity(id, &item_identity)) {
        return Err("The note's item is gone or was replaced.".into());
    }
    a.session()?.write_note_matching(id, &item_identity, &markdown).map_err(err)
}

/// Bytes pasted or dropped into the editor. The acknowledgement keeps the item protected
/// until the page has durably linked the file, or asks native code to append the link.
#[tauri::command]
fn save_media(app: AppHandle, window: tauri::Window, st: St, session_id: String, open_token: String, item_token: String, id: i64, base64: String, mime: String, name: String) -> Res<capture::Captured> {
    if window.label() != "main" { return Err("Pictures and videos are pasted into the notebook window.".into()); }
    let data = base64::engine::general_purpose::STANDARD.decode(base64.as_bytes()).map_err(|e| e.to_string())?;
    let (prefix, ext) = media::name_for(&mime, &name);
    let mut a = st.lock().unwrap();
    a.remember_current();
    let origin = a.origins.get(&open_token).cloned().filter(|o| o.session_id == session_id).ok_or("The picture's source session is no longer known.")?;
    let mut source = Session::reopen_matching(&origin.session, &origin.display_path, &origin.session_identity, &session_id, &a.store.config.header).map_err(err)?;
    let item_identity = a.item_origins.iter().find_map(|(identity, token)| (token == &item_token).then(|| identity.clone())).ok_or("The picture's source item is no longer known.")?;
    if !source.matches_item_identity(id, &item_identity) {
        return Err("The picture's source item is gone or was replaced.".into());
    }
    let s = &mut source;
    let rel = s.save_media(id, &data, prefix, &ext).map_err(err)?;
    let ack = uuid::Uuid::new_v4().to_string();
    let kind = if mime.starts_with("video/") { "video" } else { "image" };
    let link = if kind == "video" { format!("[Video]({rel})") } else { format!("![]({rel})") };
    let pending = PendingCapture {
        session: s.dir.clone(),
        display_path: origin.display_path.clone(),
        session_identity: s.folder_identity(),
        session_id: s.manifest.id.clone(),
        item: id,
        item_identity,
        link,
    };
    app.state::<Busy>().add(&pending.session, id);
    app.state::<CaptureAcks>().0.lock().unwrap().insert(ack.clone(), pending);
    Ok(capture::Captured {
        session_id: Some(session_id),
        session_path: origin.display_path,
        ack: Some(ack),
        id,
        rel,
        kind: kind.into(),
        label: String::new(),
        problem: None,
    })
}

#[tauri::command]
fn set_session_title(st: St, title: String) -> Res<View> {
    let mut a = st.lock().unwrap();
    a.session()?.set_title(&title).map_err(err)?;
    Ok(a.view())
}

#[tauri::command]
fn set_session_header(st: St, header: Option<String>) -> Res<View> {
    let mut a = st.lock().unwrap();
    a.session()?.set_header(header.as_deref()).map_err(err)?;
    Ok(a.view())
}

/// Settings the page may change. Unknown keys are ignored.
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigPatch {
    sessions_folder: Option<String>,
    folder_format: Option<String>,
    header: Option<String>,
    handoff: Option<HandoffStyle>,
    always_on_top: Option<bool>,
    annotate_screenshots: Option<bool>,
    templates: Option<Vec<Template>>,
    shortcuts: Option<Shortcuts>,
}

#[tauri::command]
fn update_config(app: tauri::AppHandle, st: St, patch: ConfigPatch) -> Res<View> {
    let mut a = st.lock().unwrap();
    a.store
        .update(|c| {
            if let Some(v) = patch.sessions_folder.filter(|v| !v.trim().is_empty()) {
                c.sessions_folder = v.trim().to_string();
            }
            if let Some(v) = patch.folder_format {
                c.folder_format = v;
            }
            if let Some(v) = patch.header {
                c.header = v;
            }
            if let Some(v) = patch.handoff {
                c.handoff = v;
            }
            if let Some(v) = patch.always_on_top {
                c.always_on_top = v;
            }
            if let Some(v) = patch.annotate_screenshots {
                c.capture.annotate_screenshots = v;
            }
            if let Some(v) = patch.templates {
                c.templates = v;
            }
            if let Some(v) = patch.shortcuts {
                c.shortcuts = v;
            }
        })
        .map_err(err)?;
    let keys = a.store.config.shortcuts.clone();
    a.shortcut_errors = register_shortcuts(&app, &keys);
    let header = a.store.config.header.clone();
    if let Some(s) = a.session.as_mut() {
        s.set_fallback_header(&header);
    }
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.set_always_on_top(a.store.config.always_on_top);
    }
    Ok(a.view())
}

/// Put the hand-off text on the clipboard and return it.
#[tauri::command]
fn copy_handoff(app: tauri::AppHandle, st: St) -> Res<String> {
    let mut a = st.lock().unwrap();
    let style = a.store.config.handoff;
    let text = a.session()?.handoff(style);
    app.clipboard().write_text(text.clone()).map_err(|e| e.to_string())?;
    Ok(text)
}

/// Show the session (or one item) in the file manager.
#[tauri::command]
fn reveal(app: tauri::AppHandle, st: St, id: Option<i64>) -> Res<()> {
    let mut a = st.lock().unwrap();
    let s = a.session()?;
    let p = match id {
        Some(id) => s.item_dir(id).map_err(err)?,
        None => s.dir.clone(),
    };
    app.opener().reveal_item_in_dir(p).map_err(|e| e.to_string())
}

/// A link clicked in a note: web and mail links open in their app; a relative link opens
/// the item's own file, never anything outside the item folder.
#[tauri::command]
fn open_link(app: tauri::AppHandle, st: St, id: Option<i64>, href: String) -> Res<()> {
    let lower = href.to_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("mailto:") {
        return app.opener().open_url(href, None::<&str>).map_err(|e| e.to_string());
    }
    let mut a = st.lock().unwrap();
    let Some(id) = id else { return Ok(()) };
    let dir = a.session()?.item_dir(id).map_err(err)?;
    let rel = percent_encoding::percent_decode_str(&href).decode_utf8_lossy().to_string();
    let Some(file) = media::contained(&dir, &rel) else { return Err("That link points outside the item.".into()) };
    // A shared session may carry anything; only open what a note's media is, never a program.
    if !media::openable(&file) {
        return Err(format!("Snagbook only opens pictures, videos and documents from a note, not {rel}."));
    }
    app.opener().open_path(file.to_string_lossy(), None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_selected(st: St, id: Option<i64>) {
    st.lock().unwrap().selected = id;
}

// Commands that open a window are async: on Windows, building a window inside a synchronous
// command (which runs on the event loop's thread) deadlocks.
#[tauri::command]
async fn start_screenshot(app: AppHandle) -> Res<()> {
    capture::start(&app, capture::Mode::Screenshot)
}

/// Record: drag the area first. When a recording is running, stop it instead.
#[tauri::command]
async fn toggle_recording(app: AppHandle) -> Res<()> {
    toggle_recording_now(&app)
}

fn toggle_recording_now(app: &AppHandle) -> Res<()> {
    if app.state::<Recorder>().0.lock().unwrap().is_some() {
        stop_recording_now(app);
        return Ok(());
    }
    if let Some(why) = record::unsupported_here(std::env::var("XDG_SESSION_TYPE").ok().as_deref(), std::env::var("WAYLAND_DISPLAY").ok().as_deref()) {
        return Err(why.into());
    }
    capture::start(app, capture::Mode::Record)
}

#[tauri::command]
async fn stop_recording(app: AppHandle) {
    stop_recording_now(&app);
}

/// The timer window's size in logical pixels, if it is open (for the self-test).
#[tauri::command]
fn recbar_size(app: AppHandle) -> Option<(f64, f64)> {
    let w = app.get_webview_window("recbar")?;
    let k = w.scale_factor().ok()?;
    let s = w.inner_size().ok()?;
    Some((s.width as f64 / k, s.height as f64 / k))
}

/// The running recording's start, for the timer window.
#[tauri::command]
fn recording_started(app: AppHandle) -> Option<u64> {
    app.state::<Recorder>().0.lock().unwrap().as_ref().map(|r| r.started_ms)
}

struct Active {
    stop: std::sync::Arc<record::Stop>,
    handle: std::thread::JoinHandle<Result<record::Finished, String>>,
    id: i64,
    /// The session the recording goes into (its folder), which may no longer be the open one
    /// when it ends.
    session: PathBuf,
    session_id: String,
    session_identity: FolderIdentity,
    item_identity: FolderIdentity,
    session_name: String,
    stem: String,
    started_ms: u64,
    ack: String,
}

/// Recordings still being finished after Stop; the app does not quit under them.
#[derive(Default)]
struct Finishing(std::sync::atomic::AtomicUsize);

/// Items a recording is writing into, from Record until its files are finished (after Stop):
/// their folders are not renamed or deleted meanwhile. Counted, as a second recording into the
/// same item can start while the first is still being finished.
#[derive(Default)]
struct Busy(Mutex<std::collections::HashMap<(PathBuf, i64), usize>>);

#[derive(Default)]
struct SessionDeleteFallback(Mutex<std::collections::HashSet<(String, String)>>);

#[derive(Clone)]
struct PendingCapture {
    session: PathBuf,
    display_path: String,
    session_identity: FolderIdentity,
    session_id: String,
    item: i64,
    item_identity: FolderIdentity,
    link: String,
}

#[derive(Default)]
struct CaptureAcks(Mutex<std::collections::HashMap<String, PendingCapture>>);

impl Busy {
    fn add(&self, session: &Path, id: i64) {
        *self.0.lock().unwrap().entry((session.to_path_buf(), id)).or_default() += 1;
    }
    /// True when this was the last recording into the item.
    fn release(&self, session: &Path, id: i64) -> bool {
        let mut m = self.0.lock().unwrap();
        let key = (session.to_path_buf(), id);
        let Some(current) = m.get(&key).copied() else { return false };
        let n = current.saturating_sub(1);
        if n == 0 {
            m.remove(&key);
        } else {
            m.insert(key, n);
        }
        n == 0
    }
    fn has(&self, session: Option<&Path>, id: i64) -> bool {
        session.is_some_and(|s| self.0.lock().unwrap().contains_key(&(s.to_path_buf(), id)))
    }

    fn has_session(&self, session: &Path) -> bool {
        self.0.lock().unwrap().keys().any(|(s, _)| s == session)
    }
}

fn release_capture(busy: &Busy, session_path: &Path, item: i64, item_identity: &FolderIdentity, session: Option<&mut Session>) {
    if busy.release(session_path, item) {
        if let Some(s) = session.filter(|s| s.matches_item_identity(item, item_identity)) {
            if let Ok(title) = s.item(item).map(|r| r.title.clone()) {
                let _ = s.retitle_item(item, &title, true);
            }
        }
    }
}

#[derive(Default)]
struct Recorder(Mutex<Option<Active>>);

/// The item a capture goes into: the shown one, or a new one (and a new session when none
/// is open).
fn target_item(a: &mut App) -> Res<i64> {
    if a.session.is_none() {
        let cfg = a.store.config.clone();
        let s = Session::create_now(&cfg.sessions_folder, &cfg).map_err(err)?;
        a.use_session(s);
    }
    let selected = a.selected;
    let s = a.session()?;
    match selected.filter(|id| s.item(*id).is_ok()) {
        Some(id) => Ok(id),
        None => Ok(s.add_item(None, Utc::now()).map_err(err)?.id),
    }
}

/// The recording's file name, held with an empty file until ffmpeg writes it: a video
/// pasted meanwhile would otherwise be given the same name and be overwritten.
fn hold_clip_name(s: &Session, id: i64) -> Res<PathBuf> {
    let (_, path) = s.reserve_media_name(id, "clip", "mp4").map_err(err)?;
    std::fs::write(&path, b"").map_err(|e| e.to_string())?;
    Ok(path)
}

fn begin_recording(app: &AppHandle, center: (i32, i32), rect: (u32, u32, u32, u32), monitor: (i32, i32, u32, u32)) -> Res<()> {
    let st = app.state::<Mutex<App>>();
    let mut a = st.lock().unwrap();
    let id = target_item(&mut a)?;
    let cap = a.store.config.capture.clone();
    let path = hold_clip_name(a.session()?, id)?;
    let (session, session_id, session_identity, item_identity, session_name) = {
        let s = a.session()?;
        (s.dir.clone(), s.manifest.id.clone(), s.folder_identity(), s.item_identity(id).map_err(err)?, s.display_path.clone())
    };
    app.state::<Busy>().add(&session, id);
    drop(a);
    let dir = path.parent().ok_or("no media folder")?.to_path_buf();
    let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).ok_or("no name")?;
    let (x, y, w, h) = rect;
    let plan = record::Plan {
        dir,
        stem: stem.clone(),
        fps: cap.fps,
        max_long_edge: cap.max_long_edge,
        max_stills: cap.max_stills,
        ffmpeg: record::find_ffmpeg(),
        source: format!("region {w}×{h} at {x},{y}"),
        destination: Some((path.parent().and_then(Path::parent).ok_or("no item folder")?.to_path_buf(), item_identity.clone())),
        finish_timeout: std::time::Duration::from_secs(60),
    };
    let stop = record::Stop::new();
    let stop2 = stop.clone();
    let handle = std::thread::spawn(move || {
        let screen = xcap::Monitor::from_point(center.0, center.1).map_err(|e| format!("The screen could not be read: {e}"))?;
        let grab = move || {
            let full = screen.capture_image().map_err(|e| format!("The screen could not be photographed: {e}"))?;
            let (fw, fh) = (full.width(), full.height());
            let img = image::RgbaImage::from_raw(fw, fh, full.into_raw()).ok_or("malformed frame")?;
            let (cw, ch) = (w.min(fw.saturating_sub(x)), h.min(fh.saturating_sub(y)));
            Ok(image::imageops::crop_imm(&img, x, y, cw.max(1), ch.max(1)).to_image())
        };
        record::run(grab, plan, stop2)
    });
    let started_ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    let ack = uuid::Uuid::new_v4().to_string();
    *app.state::<Recorder>().0.lock().unwrap() = Some(Active { stop, handle, id, session, session_id, session_identity, item_identity, session_name, stem, started_ms, ack });
    open_recbar(app, rect, monitor);
    let _ = app.emit_to("main", "recording", true);
    Ok(())
}

/// The small window with the timer and Stop, in a top corner of the recorded monitor that
/// the recorded area does not cover.
fn open_recbar(app: &AppHandle, rect: (u32, u32, u32, u32), monitor: (i32, i32, u32, u32)) {
    let (mx, my, mw, mh) = monitor;
    let scale = app
        .available_monitors()
        .ok()
        .and_then(|ms| ms.into_iter().find(|m| m.position().x == mx && m.position().y == my).map(|m| m.scale_factor()))
        .unwrap_or(1.0);
    let (bw, bh) = ((250.0 * scale) as u32, (46.0 * scale) as u32);
    let margin = (16.0 * scale) as u32;
    let overlaps = |bx: u32, by: u32| bx < rect.0 + rect.2 && rect.0 < bx + bw && by < rect.1 + rect.3 && rect.1 < by + bh;
    let spots = [(mw.saturating_sub(bw + margin), margin), (margin, margin), (mw.saturating_sub(bw + margin), mh.saturating_sub(bh + margin)), (margin, mh.saturating_sub(bh + margin))];
    let (bx, by) = spots.iter().copied().find(|(x, y)| !overlaps(*x, *y)).unwrap_or(spots[0]);
    // The last recording's bar may still be closing (Windows closes a window a moment later).
    if let Some(w) = app.get_webview_window("recbar") {
        let _ = w.destroy();
        for _ in 0..60 {
            if app.get_webview_window("recbar").is_none() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
    let built = WebviewWindowBuilder::new(app, "recbar", tauri::WebviewUrl::App("recbar.html".into()))
        .title("Snagbook recording")
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        // GTK gives a window that cannot be resized its content's natural height (about 200
        // pixels for a web view); the min and max below hold it at the bar's size instead.
        .resizable(true)
        .inner_size(250.0, 46.0)
        .min_inner_size(250.0, 46.0)
        .max_inner_size(250.0, 46.0)
        .visible(false)
        .build();
    if let Err(e) = &built {
        let _ = app.emit_to("main", "problem", format!("The recording runs, but its Stop bar could not be shown ({e}): stop it from the Record button or its shortcut."));
    }
    if let Ok(w) = built {
        let _ = w.set_size(tauri::PhysicalSize::new(bw, bh));
        let _ = w.set_position(tauri::PhysicalPosition::new(mx + bx as i32, my + by as i32));
        let _ = w.show();
        // Some window systems apply a size only to a window that is already on screen.
        let _ = w.set_size(tauri::PhysicalSize::new(bw, bh));
    }
}

/// Stop the running recording; the files are finished on a worker thread and announced.
fn stop_recording_now(app: &AppHandle) {
    let Some(active) = app.state::<Recorder>().0.lock().unwrap().take() else { return };
    if let Some(w) = app.get_webview_window("recbar") {
        let _ = w.destroy();
    }
    active.stop.request();
    app.state::<Finishing>().0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let app = app.clone();
    std::thread::spawn(move || {
        let Active { handle, id, session, session_id, session_identity, item_identity, session_name, stem, ack, .. } = active;
        let result = handle.join().unwrap_or_else(|_| Err("the recording stopped unexpectedly".into()));
        // Another recording may have started meanwhile: the button shows whichever is true now.
        let now = app.state::<Recorder>().0.lock().unwrap().is_some();
        let _ = app.emit_to("main", "recording", now);
        finish_recording(&app, Done { id, session, session_id, session_identity, item_identity, session_name, stem, ack }, result);
        let left = app.state::<Finishing>().0.fetch_sub(1, std::sync::atomic::Ordering::SeqCst) - 1;
        // The windows were closed while it finished: quit now, as closing them would have.
        if left == 0 && app.webview_windows().is_empty() {
            app.exit(0);
        }
    });
}

/// A stopped recording, as it is announced.
struct Done {
    id: i64,
    session: PathBuf,
    session_id: String,
    session_identity: FolderIdentity,
    item_identity: FolderIdentity,
    session_name: String,
    stem: String,
    ack: String,
}

fn finish_recording(app: &AppHandle, active: Done, result: Result<record::Finished, String>) {
    let outcome = result.and_then(|f| match (&f.video, &f.sheet) {
        (Some(v), _) => Ok((format!("media/{v}"), "video", f)),
        (None, Some(s)) => Ok((format!("media/{s}"), "image", f)),
        (None, None) => Err(f.problem.unwrap_or_else(|| "nothing was recorded".into())),
    });
    let st = app.state::<Mutex<App>>();
    let mut a = st.lock().unwrap();
    let open_here = a.session.as_ref().is_some_and(|s| s.manifest.id == active.session_id && s.dir == active.session && s.matches_folder_identity(&active.session_identity));
    // The session the recording went into: the open one, or its folder opened again.
    let mut other = None;
    if !open_here {
        other = Session::reopen_matching(&active.session, &active.session_name, &active.session_identity, &active.session_id, &a.store.config.header).ok();
    }
    let s = if open_here { a.session.as_mut() } else { other.as_mut() };
    let Some(s) = s.filter(|s| s.matches_item_identity(active.id, &active.item_identity)) else {
        app.state::<Busy>().release(&active.session, active.id);
        drop(a);
        let _ = app.emit_to("main", "problem", match outcome {
            Ok((rel, ..)) => format!("The recording {rel} was saved, but item {} of {} is gone, so it is in no note.", active.id, active.session_name),
            Err(e) => format!("The recording {} failed: {e}", active.stem),
        });
        return;
    };
    let (rel, kind, f) = match outcome {
        Ok(o) => o,
        Err(e) => {
            app.state::<Busy>().release(&active.session, active.id);
            drop(a);
            let _ = app.emit_to("main", "problem", format!("The recording {} failed: {e}", active.stem));
            return;
        }
    };
    let label = format!("Recording {}", snagbook_core::capture_math::duration(f.duration));
    let link = if kind == "video" { format!("[{label}]({rel})") } else { format!("![{label}]({rel})") };
    // Shown in the notebook: its editor adds the link where the note is being written.
    if open_here && app.get_webview_window("main").is_some() {
        app.state::<CaptureAcks>().0.lock().unwrap().insert(active.ack.clone(), PendingCapture {
            session: active.session.clone(), display_path: active.session_name.clone(), session_identity: active.session_identity.clone(), session_id: s.manifest.id.clone(), item: active.id, item_identity: active.item_identity.clone(), link,
        });
        let session_id = s.manifest.id.clone();
        drop(a);
        capture::announce(app, capture::Captured {
            session_id: Some(session_id),
            session_path: active.session_name.clone(),
            ack: Some(active.ack),
            id: active.id,
            rel,
            kind: kind.into(),
            label,
            problem: f.problem,
        });
        return;
    }
    // Otherwise (another session open, or the notebook closed) the link goes at the end of
    // the item's note here.
    let body = s.read_note(active.id).unwrap_or_default();
    let body = body.trim_end();
    let written = s.write_note_matching(active.id, &active.item_identity, &if body.is_empty() { format!("{link}\n") } else { format!("{body}\n\n{link}\n") });
    let last = app.state::<Busy>().release(&active.session, active.id);
    if last {
        if s.matches_item_identity(active.id, &active.item_identity) {
            if let Ok(title) = s.item(active.id).map(|r| r.title.clone()) { let _ = s.retitle_item(active.id, &title, true); }
        }
    }
    let title = s.item(active.id).map(|r| r.title.clone()).unwrap_or_default();
    drop(a);
    let _ = app.emit_to("main", "problem", match written {
        Ok(_) => format!("The recording was added to the end of “{title}” in {}.", active.session_name),
        Err(e) => format!("The recording {rel} was saved in {}, but its note could not be written: {e}", active.session_name),
    });
}

#[tauri::command]
fn capture_filed(app: AppHandle, window: tauri::Window, st: St, ack: String, inserted: bool) -> Res<()> {
    if window.label() != "main" { return Err("Captures are filed from the notebook window.".into()); }
    let pending = app.state::<CaptureAcks>().0.lock().unwrap().get(&ack).cloned().ok_or("That capture is not waiting to be filed.")?;
    let mut a = st.lock().unwrap();
    if inserted {
        if a.session.as_ref().is_none_or(|s| s.manifest.id != pending.session_id || !s.matches_folder_identity(&pending.session_identity) || !s.matches_item_identity(pending.item, &pending.item_identity)) {
            return Err("The capture's session or item is no longer open.".into());
        }
    } else {
        file_pending_capture(&pending, &a.store.config.header)?;
    }
    app.state::<CaptureAcks>().0.lock().unwrap().remove(&ack);
    release_capture(
        app.state::<Busy>().inner(),
        &pending.session,
        pending.item,
        &pending.item_identity,
        a.session.as_mut().filter(|s| s.manifest.id == pending.session_id),
    );
    Ok(())
}

fn file_pending_capture(pending: &PendingCapture, fallback_header: &str) -> Res<()> {
    let mut s = Session::reopen_matching(&pending.session, &pending.display_path, &pending.session_identity, &pending.session_id, fallback_header).map_err(err)?;
    if !s.matches_item_identity(pending.item, &pending.item_identity) {
        return Err("The capture's item is gone or was replaced.".into());
    }
    append_capture_link(&mut s, pending.item, &pending.item_identity, &pending.link)
}

fn append_capture_link(s: &mut Session, item: i64, identity: &FolderIdentity, link: &str) -> Res<()> {
    let body = s.read_note(item).map_err(err)?;
    if body.lines().any(|line| line.trim() == link) { return Ok(()) }
    let body = body.trim_end();
    if let Err(e) = s.write_note_matching(item, identity, &if body.is_empty() { format!("{link}\n") } else { format!("{body}\n\n{link}\n") }) {
        if s.read_note(item).is_ok_and(|written| written.lines().any(|line| line.trim() == link)) { return Ok(()) }
        return Err(err(e));
    }
    Ok(())
}

#[tauri::command]
fn capture_can_insert(app: AppHandle, window: tauri::Window, st: St, ack: String) -> Res<bool> {
    if window.label() != "main" { return Err("Captures are filed from the notebook window.".into()); }
    let pending = app.state::<CaptureAcks>().0.lock().unwrap().get(&ack).cloned().ok_or("That capture is not waiting to be filed.")?;
    let a = st.lock().unwrap();
    Ok(a.session.as_ref().is_some_and(|s| {
        s.manifest.id == pending.session_id
            && s.matches_folder_identity(&pending.session_identity)
            && s.matches_item_identity(pending.item, &pending.item_identity)
    }))
}

#[tauri::command]
async fn cancel_screenshot(app: AppHandle) {
    capture::close(&app);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
    }
}

/// The rectangle is chosen: a screenshot is cropped and saved into the shown item (a new
/// one when nothing is shown, a new session when none is open); a recording starts.
#[tauri::command]
async fn finish_screenshot(app: AppHandle, rect: capture::Rect) -> Res<()> {
    let r = finish_capture(&app, rect);
    // The capture window closes on an error; say why in the notebook, or it just vanishes.
    if let Err(e) = &r {
        let _ = app.emit_to("main", "problem", format!("The screenshot could not be saved: {e}"));
    }
    r
}

fn finish_capture(app: &AppHandle, rect: capture::Rect) -> Res<()> {
    let app = app.clone();
    let png = match capture::finish(&app, rect)? {
        capture::Chosen::Picture(png) => png,
        capture::Chosen::Region { center, rect, monitor } => return begin_recording(&app, center, rect, monitor),
    };
    let st = app.state::<Mutex<App>>();
    let mut a = st.lock().unwrap();
    let id = target_item(&mut a)?;
    let rel = a.session()?.save_media(id, &png, "shot", "png").map_err(err)?;
    let annotate = a.store.config.capture.annotate_screenshots;
    let ack = uuid::Uuid::new_v4().to_string();
    let s = a.session.as_ref().ok_or("No session is open.")?;
    let session_id = s.manifest.id.clone();
    let session_path = s.display_path.clone();
    let session_dir = s.dir.clone();
    let session_identity = s.folder_identity();
    let item_identity = s.item_identity(id).map_err(err)?;
    let marked = if annotate {
        Some(pending_markup(&mut a, id, rel.clone(), true, None, Some(ack.clone()), app.state::<SelftestNext>().0.lock().unwrap().take())?)
    } else {
        None
    };
    app.state::<Busy>().add(&session_dir, id);
    app.state::<CaptureAcks>().0.lock().unwrap().insert(ack.clone(), PendingCapture {
        session: session_dir,
        display_path: session_path.clone(),
        session_identity,
        session_id: session_id.clone(),
        item: id,
        item_identity,
        link: format!("![]({rel})"),
    });
    drop(a);
    if let Some(p) = marked {
        if show_markup(&app, p).is_ok() {
            return Ok(());
        }
    }
    capture::announce(&app, capture::Captured {
        session_id: Some(session_id),
        session_path,
        ack: Some(ack),
        id,
        rel,
        kind: "image".into(),
        label: String::new(),
        problem: None,
    });
    Ok(())
}

// ---------------------------------------------------------------- mark-up

#[derive(Default)]
struct Markup(Mutex<Option<markup::Pending>>);

/// The self-test's script for the next mark-up window.
#[derive(Default)]
struct SelftestNext(Mutex<Option<String>>);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Marked {
    session_id: String,
    session_path: String,
    ack: Option<String>,
    id: i64,
    rel: String,
    is_new: bool,
    /// False when a new screenshot was thrown away.
    kept: bool,
    /// True when the picture's pixels changed.
    changed: bool,
}

fn markup_files(p: &markup::Pending) -> Res<markup::Files> {
    let session = Session::reopen_matching(&p.session_dir, &p.session_path, &p.session_identity, &p.session_id, "").map_err(err)?;
    if !session.matches_item_identity(p.id, &p.item_identity) {
        return Err("The item containing this picture is gone or was replaced.".into());
    }
    markup::files(&p.item_dir, &p.rel).ok_or_else(|| format!("{} is not a picture in this item.", p.rel))
}

fn pending_markup(a: &mut App, id: i64, rel: String, is_new: bool, item_identity: Option<FolderIdentity>, ack: Option<String>, auto: Option<String>) -> Res<markup::Pending> {
    let fallback_header = a.store.config.header.clone();
    let s = a.session()?;
    Ok(markup::Pending {
        id,
        rel,
        is_new,
        session_id: s.manifest.id.clone(),
        session_path: s.display_path.clone(),
        session_dir: s.dir.clone(),
        session_identity: s.folder_identity(),
        item_identity: item_identity.map_or_else(|| s.item_identity(id), Ok).map_err(err)?,
        item_dir: s.item_dir(id).map_err(err)?,
        fallback_header,
        ack,
        auto,
    })
}

fn show_markup(app: &AppHandle, p: markup::Pending) -> Res<()> {
    markup_files(&p)?;
    if let Some(w) = app.get_webview_window(markup::WINDOW) {
        let _ = w.set_focus();
        return Err("Finish the picture that is already open first.".into());
    }
    let name = p.rel.rsplit('/').next().unwrap_or(&p.rel).to_string();
    *app.state::<Markup>().0.lock().unwrap() = Some(p);
    let w = WebviewWindowBuilder::new(app, markup::WINDOW, tauri::WebviewUrl::App("annotate.html".into()))
        .title(format!("Mark up — {name}"))
        .inner_size(1040.0, 720.0)
        .min_inner_size(560.0, 360.0)
        .center()
        .build()
        .map_err(|e| e.to_string())?;
    let _ = w.set_focus();
    Ok(())
}

fn open_markup_now(app: &AppHandle, id: i64, rel: String, is_new: bool, auto: Option<String>) -> Res<()> {
    let p = {
        let st = app.state::<Mutex<App>>();
        let mut a = st.lock().unwrap();
        pending_markup(&mut a, id, rel, is_new, None, None, auto)?
    };
    show_markup(app, p)
}

/// Mark up a picture already in a note (double-click it).
#[tauri::command]
async fn open_markup(app: AppHandle, st: St<'_>, session_id: String, open_token: String, item_token: String, id: i64, rel: String) -> Res<()> {
    let p = {
        let mut a = st.lock().unwrap();
        if a.session.as_ref().is_none_or(|s| s.manifest.id != session_id || s.open_token != open_token) {
            return Err("The picture's session is no longer open.".into());
        }
        let item_identity = a.item_origins.iter().find_map(|(identity, token)| (token == &item_token).then(|| identity.clone())).ok_or("The picture's source item is no longer known.")?;
        if a.session.as_ref().is_none_or(|s| !s.matches_item_identity(id, &item_identity)) {
            return Err("The picture's source item is gone or was replaced.".into());
        }
        pending_markup(&mut a, id, rel, false, Some(item_identity), None, None)?
    };
    show_markup(&app, p)
}

#[tauri::command]
fn markup_info(app: AppHandle) -> Res<markup::Info> {
    let p = app.state::<Markup>().0.lock().unwrap().clone().ok_or("No picture is being marked up.")?;
    let f = markup_files(&p)?;
    Ok(markup::info(&f, &p))
}

fn finish_markup(app: &AppHandle, kept: bool, changed: bool) -> Res<()> {
    let st = app.state::<Mutex<App>>();
    let mut a = st.lock().unwrap();
    let markup_state = app.state::<Markup>();
    let mut markup = markup_state.0.lock().unwrap();
    let Some(p) = markup.as_ref().cloned() else { return Ok(()) };

    let open_here = a.session.as_ref().is_some_and(|s| {
        s.manifest.id == p.session_id
            && s.matches_folder_identity(&p.session_identity)
            && s.matches_item_identity(p.id, &p.item_identity)
    });
    let mut other = None;
    if !open_here {
        other = Session::reopen_matching(&p.session_dir, &p.session_path, &p.session_identity, &p.session_id, &p.fallback_header)
            .ok()
            .filter(|s| s.matches_item_identity(p.id, &p.item_identity));
    }
    let file_without_notebook = p.is_new && kept && app.get_webview_window("main").is_none();
    let mut event_ack = p.ack.clone();
    let source = if open_here { a.session.as_mut() } else { other.as_mut() };
    let Some(s) = source else { return Err("The item containing this picture is gone or was replaced.".into()) };
    if p.is_new && !kept {
        if let Some(ack) = &p.ack {
            app.state::<CaptureAcks>().0.lock().unwrap().remove(ack);
            app.state::<Busy>().release(&p.session_dir, p.id);
        }
    }
    {
        if file_without_notebook {
            if let Some(ack) = &p.ack {
                if append_capture_link(s, p.id, &p.item_identity, &format!("![]({})", p.rel)).is_ok() {
                    app.state::<CaptureAcks>().0.lock().unwrap().remove(ack);
                    app.state::<Busy>().release(&p.session_dir, p.id);
                    event_ack = None;
                }
            }
        }
        let _ = s.write_readme();
        if !app.state::<Busy>().has(Some(&s.dir), p.id) {
            if let Ok(title) = s.item(p.id).map(|r| r.title.clone()) {
                let _ = s.retitle_item(p.id, &title, true);
            }
        }
    }

    markup.take();
    drop(markup);
    drop(a);
    if let Some(w) = app.get_webview_window(markup::WINDOW) {
        let _ = w.destroy();
    }
    let _ = app.emit_to("main", "marked", Marked {
        session_id: p.session_id,
        session_path: p.session_path,
        ack: event_ack,
        id: p.id,
        rel: p.rel,
        is_new: p.is_new,
        kept,
        changed,
    });
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
    Ok(())
}

/// Done: `png` (base64) and `marks` (JSON) to save, or neither to put the original back.
#[tauri::command]
async fn save_markup(app: AppHandle, png: Option<String>, marks: Option<String>) -> Res<()> {
    let st = app.state::<Mutex<App>>();
    let _app_guard = st.lock().unwrap();
    let p = app.state::<Markup>().0.lock().unwrap().clone().ok_or("No picture is being marked up.")?;
    let f = markup_files(&p)?;
    let bytes = match &png {
        Some(b) => Some(base64::engine::general_purpose::STANDARD.decode(b.as_bytes()).map_err(|e| e.to_string())?),
        None => None,
    };
    markup::save(&f, bytes.as_deref(), marks.as_deref())?;
    drop(_app_guard);
    finish_markup(&app, true, true)
}

/// No Marks / Cancel: the picture stays as it was.
#[tauri::command]
async fn skip_markup(app: AppHandle) -> Res<()> {
    finish_markup(&app, true, false)
}

/// A new screenshot is thrown away.
#[tauri::command]
async fn discard_markup(app: AppHandle) -> Res<()> {
    let p = app.state::<Markup>().0.lock().unwrap().clone().ok_or("No picture is being marked up.")?;
    if p.is_new {
        let f = markup_files(&p)?;
        let _ = std::fs::remove_file(&f.picture);
    }
    finish_markup(&app, !p.is_new, false)
}

#[tauri::command]
fn markup_open(app: AppHandle) -> bool {
    app.get_webview_window(markup::WINDOW).is_some()
}

/// The self-test's script for the next mark-up window.
#[tauri::command]
fn selftest_markup_next(app: AppHandle, script: String) -> Res<()> {
    if !selftest_requested() {
        return Err("Only during the self-test.".into());
    }
    *app.state::<SelftestNext>().0.lock().unwrap() = Some(script);
    Ok(())
}

/// Mark up an existing picture with a self-test script.
#[tauri::command]
async fn selftest_open_markup(app: AppHandle, id: i64, rel: String, script: String) -> Res<()> {
    if !selftest_requested() {
        return Err("Only during the self-test.".into());
    }
    open_markup_now(&app, id, rel, false, Some(script))
}

/// Whether the screenshot window is open (for the self-test).
#[tauri::command]
fn capture_open(app: AppHandle) -> bool {
    app.get_webview_window(capture::WINDOW).is_some()
}

/// What a global shortcut does.
#[derive(Clone, Copy)]
enum Action {
    Screenshot,
    Record,
    NewItem,
    ShowNotebook,
}

#[derive(Default)]
struct Bindings(Mutex<Vec<(Shortcut, Action)>>);

/// (Re)register the global shortcuts; returns what could not be registered, in words.
fn register_shortcuts(app: &AppHandle, keys: &Shortcuts) -> Vec<String> {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    let mut bound = vec![];
    let mut errors = vec![];
    for (name, text, action) in [
        ("Screenshot", &keys.screenshot, Action::Screenshot),
        ("Record", &keys.record, Action::Record),
        ("New item", &keys.new_item, Action::NewItem),
        ("Show notebook", &keys.show_notebook, Action::ShowNotebook),
    ] {
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        match text.parse::<Shortcut>() {
            Err(e) => errors.push(format!("{name}: “{text}” is not a shortcut ({e})")),
            Ok(sc) => match gs.register(sc) {
                Ok(()) => bound.push((sc, action)),
                Err(e) => errors.push(format!("{name}: {text} could not be registered ({e})")),
            },
        }
    }
    *app.state::<Bindings>().0.lock().unwrap() = bound;
    errors
}

fn on_shortcut(app: &AppHandle, sc: &Shortcut) {
    let action = app.state::<Bindings>().0.lock().unwrap().iter().find(|(s, _)| s == sc).map(|(_, a)| *a);
    let main = app.get_webview_window("main");
    match action {
        // Off the event loop's thread, for the same reason the commands are async.
        Some(Action::Screenshot) => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = capture::start(&app, capture::Mode::Screenshot) {
                    let _ = app.emit_to("main", "problem", e);
                }
            });
        }
        Some(Action::Record) => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = toggle_recording_now(&app) {
                    let _ = app.emit_to("main", "problem", e);
                }
            });
        }
        Some(Action::NewItem) => {
            if let Some(w) = main {
                let _ = w.show();
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
            let _ = app.emit_to("main", "new-item", ());
        }
        Some(Action::ShowNotebook) => {
            if let Some(w) = main {
                if w.is_focused().unwrap_or(false) && w.is_visible().unwrap_or(false) {
                    let _ = w.minimize();
                } else {
                    let _ = w.show();
                    let _ = w.unminimize();
                    let _ = w.set_focus();
                }
            }
        }
        None => {}
    }
}

/// SNAGBOOK_SELFTEST=1 runs the page's self-test and exits with its verdict.
#[tauri::command]
fn selftest_requested() -> bool {
    std::env::var("SNAGBOOK_SELFTEST").is_ok_and(|v| !v.is_empty())
}

/// One self-test line, as soon as it is known: a run that hangs still shows how far it got.
#[tauri::command]
fn selftest_log(line: String) {
    if !selftest_requested() {
        return;
    }
    println!("{line}");
    if let Ok(out) = std::env::var("SNAGBOOK_SELFTEST_OUT") {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(format!("{out}.progress")) {
            let _ = writeln!(f, "{line}");
        }
    }
}

/// Whether recordings can be saved as video here.
#[tauri::command]
fn ffmpeg_found() -> bool {
    record::find_ffmpeg().is_some()
}

#[tauri::command]
fn selftest_mode() -> String {
    std::env::var("SNAGBOOK_SELFTEST").unwrap_or_default()
}

/// Deletes the open session's folder from outside the app, for the self-test only.
#[tauri::command]
fn selftest_delete_session(st: St) -> Res<()> {
    if !selftest_requested() {
        return Err("Only during the self-test.".into());
    }
    let dir = st.lock().unwrap().session()?.dir.clone();
    std::fs::remove_dir_all(dir).map_err(|e| e.to_string())
}

#[tauri::command]
fn selftest_done(app: tauri::AppHandle, ok: bool, lines: Vec<String>) {
    // Only the self-test may end the app this way.
    if !selftest_requested() {
        return;
    }
    let verdict = if ok { "SELFTEST PASS" } else { "SELFTEST FAIL" };
    println!("{verdict}");
    // A Windows GUI program has no console: SNAGBOOK_SELFTEST_OUT names a file for the verdict.
    if let Ok(out) = std::env::var("SNAGBOOK_SELFTEST_OUT") {
        let _ = std::fs::write(out, format!("{}\n{verdict}\n", lines.join("\n")));
    }
    // AppHandle::exit does not carry the code to the process on every platform; the verdict
    // is the exit status, so leave directly.
    let _ = app;
    std::process::exit(if ok { 0 } else { 1 });
}

/// Files an item may serve: the resolved path must stay inside the item folder.
pub(crate) fn item_file(app: &tauri::AppHandle, id: i64, rel: &str) -> Option<PathBuf> {
    let st = app.state::<Mutex<App>>();
    let a = st.lock().ok()?;
    let dir = a.session.as_ref()?.item_dir(id).ok()?;
    media::contained(&dir, rel)
}

pub(crate) fn markup_file(app: &tauri::AppHandle, rel: &str) -> Option<PathBuf> {
    let p = app.state::<Markup>().0.lock().ok()?.clone()?;
    markup_files(&p).ok()?;
    media::contained(&p.item_dir, rel)
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(w) = app.get_webview_window("main") { let _ = w.show(); let _ = w.unminimize(); let _ = w.set_focus(); }
        }))
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, sc, event| {
                    if event.state() == ShortcutState::Pressed {
                        on_shortcut(app, sc);
                    }
                })
                .build(),
        )
        .manage(Mutex::new(App::load()))
        .manage(capture::Frozen::default())
        .manage(Recorder::default())
        .manage(Finishing::default())
        .manage(Busy::default())
        .manage(SessionDeleteFallback::default())
        .manage(CaptureAcks::default())
        .manage(Markup::default())
        .manage(SelftestNext::default())
        .on_window_event(|w, e| {
            // The mark-up window closed with its close button: the picture stays as it was.
            if w.label() == markup::WINDOW && matches!(e, tauri::WindowEvent::Destroyed) {
                if let Err(e) = finish_markup(w.app_handle(), true, false) {
                    if let Some(p) = w.app_handle().state::<Markup>().0.lock().unwrap().take() {
                        if let Some(ack) = p.ack {
                            w.app_handle().state::<CaptureAcks>().0.lock().unwrap().remove(&ack);
                            w.app_handle().state::<Busy>().release(&p.session_dir, p.id);
                        }
                    }
                    let _ = w.app_handle().emit_to("main", "problem", e);
                }
            }
        })
        .manage(Bindings::default())
        .register_uri_scheme_protocol("snagbook", |ctx, request| media::serve(ctx.app_handle(), &request))
        .setup(|app| {
            let (on_top, keys) = {
                let st = app.state::<Mutex<App>>();
                let a = st.lock().unwrap();
                (a.store.config.always_on_top, a.store.config.shortcuts.clone())
            };
            let errors = register_shortcuts(app.handle(), &keys);
            app.state::<Mutex<App>>().lock().unwrap().shortcut_errors = errors;
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.set_always_on_top(on_top);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            state,
            list_sessions,
            new_session,
            open_session,
            pick_session_folder,
            add_item,
            rename_item,
            delete_item,
            delete_session,
            move_item,
            read_note,
            write_note,
            save_media,
            set_session_title,
            set_session_header,
            update_config,
            copy_handoff,
            reveal,
            open_link,
            set_selected,
            start_screenshot,
            toggle_recording,
            stop_recording,
            recording_started,
            recbar_size,
            open_markup,
            markup_info,
            save_markup,
            skip_markup,
            discard_markup,
            markup_open,
            selftest_markup_next,
            selftest_open_markup,
            cancel_screenshot,
            finish_screenshot,
            capture_filed,
            capture_can_insert,
            capture_open,
            selftest_requested,
            selftest_mode,
            selftest_log,
            ffmpeg_found,
            selftest_delete_session,
            selftest_done,
        ])
        .build(tauri::generate_context!())
        .expect("Snagbook could not start")
        .run(|app, event| {
            // Closing the last window while a recording is being finished waits for it.
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = event {
                if app.state::<Finishing>().0.load(std::sync::atomic::Ordering::SeqCst) > 0 {
                    api.prevent_exit();
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_video_pasted_during_a_recording_gets_its_own_name() {
        let d = tempfile::tempdir().unwrap();
        let mut s = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let id = s.add_item(None, Utc::now()).unwrap().id;
        let held = hold_clip_name(&s, id).unwrap();
        assert_eq!(held.file_name().unwrap(), "clip-001.mp4");
        assert_eq!(s.save_media(id, b"pasted", "clip", "mp4").unwrap(), "media/clip-002.mp4");
        assert_eq!(std::fs::read(&held).unwrap(), b"");
    }

    #[test]
    fn a_recording_stays_busy_until_its_last_writer_releases_it() {
        let busy = Busy::default();
        let session = Path::new("/session");
        busy.add(session, 1);
        busy.add(session, 1);
        assert!(busy.has_session(session));
        assert!(!busy.release(session, 1));
        assert!(busy.has(Some(session), 1));
        assert!(busy.release(session, 1));
        assert!(!busy.has_session(session));
        assert!(!busy.release(session, 1), "an unknown writer is never reported as the last one");
    }

    #[test]
    fn a_durable_capture_link_survives_a_readme_failure_without_duplicates() {
        let d = tempfile::tempdir().unwrap();
        let mut s = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let id = s.add_item(None, Utc::now()).unwrap().id;
        let readme = s.dir.join("README.md");
        std::fs::remove_file(&readme).unwrap();
        std::fs::create_dir(&readme).unwrap();
        let link = "![](media/image-001.png)";
        let identity = s.item_identity(id).unwrap();

        append_capture_link(&mut s, id, &identity, link).unwrap();
        append_capture_link(&mut s, id, &identity, link).unwrap();

        let note = s.read_note(id).unwrap();
        assert_eq!(note.lines().filter(|line| line.trim() == link).count(), 1);
    }

    #[test]
    fn fallback_filing_keeps_the_source_display_path() {
        let d = tempfile::tempdir().unwrap();
        let mut s = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let id = s.add_item(None, Utc::now()).unwrap().id;
        let pending = PendingCapture {
            session: s.dir.clone(),
            display_path: "~/shared-session-link".into(),
            session_identity: s.folder_identity(),
            session_id: s.manifest.id.clone(),
            item: id,
            item_identity: s.item_identity(id).unwrap(),
            link: "![](media/image-001.png)".into(),
        };

        file_pending_capture(&pending, "Review {session}").unwrap();

        assert!(std::fs::read_to_string(s.dir.join("README.md")).unwrap().starts_with("Review ~/shared-session-link\n"));
    }

    #[test]
    fn fallback_filing_does_not_repair_a_replacement_session() {
        let d = tempfile::tempdir().unwrap();
        let mut original = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let id = original.add_item(None, Utc::now()).unwrap().id;
        let pending = PendingCapture {
            session: original.dir.clone(),
            display_path: original.display_path.clone(),
            session_identity: original.folder_identity(),
            session_id: original.manifest.id.clone(),
            item: id,
            item_identity: original.item_identity(id).unwrap(),
            link: "![](media/image-001.png)".into(),
        };
        let held = original.dir.with_file_name("held-original-fallback");
        std::fs::rename(&original.dir, held).unwrap();
        let mut replacement = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let replacement_item = replacement.add_item(None, Utc::now()).unwrap();
        std::fs::remove_dir_all(replacement.item_dir(replacement_item.id).unwrap()).unwrap();
        std::fs::rename(&replacement.dir, &original.dir).unwrap();
        let manifest = std::fs::read(original.dir.join("session.json")).unwrap();
        let readme = std::fs::read(original.dir.join("README.md")).unwrap();

        assert!(file_pending_capture(&pending, "replacement must not be rewritten").is_err());
        assert_eq!(std::fs::read(original.dir.join("session.json")).unwrap(), manifest);
        assert_eq!(std::fs::read(original.dir.join("README.md")).unwrap(), readme);
    }

    #[test]
    fn pending_capture_and_markup_refuse_a_replacement_item_folder() {
        let d = tempfile::tempdir().unwrap();
        let mut s = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let id = s.add_item(None, Utc::now()).unwrap().id;
        let rel = s.save_media(id, b"original", "image", "png").unwrap();
        let item_dir = s.item_dir(id).unwrap();
        let item_identity = s.item_identity(id).unwrap();
        let capture = PendingCapture {
            session: s.dir.clone(),
            display_path: s.display_path.clone(),
            session_identity: s.folder_identity(),
            session_id: s.manifest.id.clone(),
            item: id,
            item_identity: item_identity.clone(),
            link: format!("![]({rel})"),
        };
        let markup = markup::Pending {
            id,
            rel: rel.clone(),
            is_new: false,
            session_id: s.manifest.id.clone(),
            session_path: s.display_path.clone(),
            session_dir: s.dir.clone(),
            session_identity: s.folder_identity(),
            item_identity,
            item_dir: item_dir.clone(),
            fallback_header: String::new(),
            ack: None,
            auto: None,
        };
        let held = s.dir.join("held-item");
        std::fs::rename(&item_dir, held).unwrap();
        std::fs::create_dir(&item_dir).unwrap();
        std::fs::write(item_dir.join("notes.md"), "replacement\n").unwrap();
        std::fs::create_dir(item_dir.join("media")).unwrap();
        let replacement = item_dir.join(&rel);
        std::fs::write(&replacement, b"replacement").unwrap();

        assert!(file_pending_capture(&capture, "").is_err());
        assert!(markup_files(&markup).is_err());
        assert_eq!(std::fs::read_to_string(item_dir.join("notes.md")).unwrap(), "replacement\n");
        assert_eq!(std::fs::read(replacement).unwrap(), b"replacement");
    }

    #[test]
    fn a_deferred_folder_rename_failure_does_not_turn_a_filed_capture_into_a_retry() {
        let d = tempfile::tempdir().unwrap();
        let mut s = Session::create_now(&d.path().to_string_lossy(), &Config::default()).unwrap();
        let id = s.add_item(None, Utc::now()).unwrap().id;
        s.retitle_item(id, "Renamed", false).unwrap();
        let item_identity = s.item_identity(id).unwrap();
        let item_dir = s.item_dir(id).unwrap();
        std::fs::remove_dir_all(item_dir).unwrap();
        let busy = Busy::default();
        busy.add(&s.dir, id);
        let session_path = s.dir.clone();

        release_capture(&busy, &session_path, id, &item_identity, Some(&mut s));

        assert!(!busy.has(Some(&session_path), id));
    }
}
