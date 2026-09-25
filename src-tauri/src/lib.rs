//! The notebook window: commands the page calls, and the snagbook: scheme that serves an
//! item's pictures and videos to the editor.

mod capture;
mod media;
mod record;

use base64::Engine;
use chrono::Utc;
use serde::Serialize;
use snagbook_core::{Config, ConfigStore, HandoffStyle, Paths, Session, Shortcuts, SnagError, Summary, Template};
use std::path::PathBuf;
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
    title: String,
    folder: String,
    images: usize,
    videos: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
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
        App { store, session, selected: None, shortcut_errors: vec![] }
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
            path: s.display_path.clone(),
            title: s.title(),
            header: s.manifest.header.clone(),
            items: s
                .manifest
                .items
                .iter()
                .map(|r| {
                    let c = s.media_count(r.id);
                    ItemView { id: r.id, title: r.title.clone(), folder: r.folder.clone(), images: c.images, videos: c.videos }
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
        self.session = Some(s);
        let _ = self.store.update(|c| c.last_session = Some(path));
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
fn rename_item(st: St, id: i64, title: String) -> Res<View> {
    let mut a = st.lock().unwrap();
    a.session()?.rename_item(id, &title).map_err(err)?;
    Ok(a.view())
}

/// Move an item's folder to the Trash. When that is impossible the answer starts with
/// "NOTRASH:" and the page asks before calling again with `permanently`.
#[tauri::command]
fn delete_item(st: St, id: i64, permanently: bool) -> Res<View> {
    let mut a = st.lock().unwrap();
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
fn move_item(st: St, id: i64, index: usize) -> Res<View> {
    let mut a = st.lock().unwrap();
    a.session()?.move_item(id, index).map_err(err)?;
    Ok(a.view())
}

#[tauri::command]
fn read_note(st: St, id: i64) -> Res<String> {
    let mut a = st.lock().unwrap();
    a.session()?.read_note(id).map_err(err)
}

#[tauri::command]
fn write_note(st: St, id: i64, markdown: String) -> Res<bool> {
    let mut a = st.lock().unwrap();
    a.session()?.write_note(id, &markdown).map_err(err)
}

/// Bytes pasted or dropped into the editor. Returns the note-relative path.
#[tauri::command]
fn save_media(st: St, id: i64, base64: String, mime: String, name: String) -> Res<String> {
    let data = base64::engine::general_purpose::STANDARD.decode(base64.as_bytes()).map_err(|e| e.to_string())?;
    let (prefix, ext) = media::name_for(&mime, &name);
    let mut a = st.lock().unwrap();
    a.session()?.save_media(id, &data, prefix, &ext).map_err(err)
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
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    handle: std::thread::JoinHandle<Result<record::Finished, String>>,
    id: i64,
    stem: String,
    started_ms: u64,
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

fn begin_recording(app: &AppHandle, center: (i32, i32), rect: (u32, u32, u32, u32), monitor: (i32, i32, u32, u32)) -> Res<()> {
    let st = app.state::<Mutex<App>>();
    let mut a = st.lock().unwrap();
    let id = target_item(&mut a)?;
    let cap = a.store.config.capture.clone();
    let (_, path) = a.session()?.reserve_media_name(id, "clip", "mp4").map_err(err)?;
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
    };
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
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
    *app.state::<Recorder>().0.lock().unwrap() = Some(Active { stop, handle, id, stem, started_ms });
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
    if let Ok(w) = WebviewWindowBuilder::new(app, "recbar", tauri::WebviewUrl::App("recbar.html".into()))
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
        .build()
    {
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
    active.stop.store(true, std::sync::atomic::Ordering::SeqCst);
    let app = app.clone();
    std::thread::spawn(move || {
        let result = active.handle.join().unwrap_or_else(|_| Err("the recording stopped unexpectedly".into()));
        let _ = app.emit_to("main", "recording", false);
        match result {
            Ok(f) => {
                let (rel, kind) = match (&f.video, &f.sheet) {
                    (Some(v), _) => (format!("media/{v}"), "video"),
                    (None, Some(s)) => (format!("media/{s}"), "image"),
                    (None, None) => {
                        let _ = app.emit_to("main", "problem", f.problem.unwrap_or_else(|| "Nothing was recorded.".into()));
                        return;
                    }
                };
                let label = format!("Recording {}", snagbook_core::capture_math::duration(f.duration));
                capture::announce(&app, capture::Captured { id: active.id, rel, kind: kind.into(), label, problem: f.problem });
            }
            Err(e) => {
                let _ = app.emit_to("main", "problem", format!("The recording {} failed: {e}", active.stem));
            }
        }
    });
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
    let png = match capture::finish(&app, rect)? {
        capture::Chosen::Picture(png) => png,
        capture::Chosen::Region { center, rect, monitor } => return begin_recording(&app, center, rect, monitor),
    };
    let st = app.state::<Mutex<App>>();
    let mut a = st.lock().unwrap();
    let id = target_item(&mut a)?;
    let rel = a.session()?.save_media(id, &png, "shot", "png").map_err(err)?;
    drop(a);
    capture::announce(&app, capture::Captured { id, rel, kind: "image".into(), label: String::new(), problem: None });
    Ok(())
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

pub fn run() {
    tauri::Builder::default()
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
            cancel_screenshot,
            finish_screenshot,
            capture_open,
            selftest_requested,
            selftest_mode,
            selftest_log,
            ffmpeg_found,
            selftest_delete_session,
            selftest_done,
        ])
        .run(tauri::generate_context!())
        .expect("Snagbook could not start");
}
