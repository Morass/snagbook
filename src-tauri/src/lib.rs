//! The notebook window: commands the page calls, and the snagbook: scheme that serves an
//! item's pictures and videos to the editor.

mod media;

use base64::Engine;
use chrono::Utc;
use serde::Serialize;
use snagbook_core::{Config, ConfigStore, HandoffStyle, Paths, Session, SnagError, Summary, Template};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Manager, State};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

pub struct App {
    pub store: ConfigStore,
    pub session: Option<Session>,
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
        App { store, session }
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
        View { config: self.store.config.clone(), session, load_error: self.store.load_error.clone(), closed, platform: platform() }
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
fn state(st: St) -> View {
    st.lock().unwrap().view()
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
        })
        .map_err(err)?;
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

/// SNAGBOOK_SELFTEST=1 runs the page's self-test and exits with its verdict.
#[tauri::command]
fn selftest_requested() -> bool {
    std::env::var("SNAGBOOK_SELFTEST").is_ok_and(|v| !v.is_empty())
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
    for l in &lines {
        println!("{l}");
    }
    println!("{}", if ok { "SELFTEST PASS" } else { "SELFTEST FAIL" });
    app.exit(if ok { 0 } else { 1 });
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
        .manage(Mutex::new(App::load()))
        .register_uri_scheme_protocol("snagbook", |ctx, request| media::serve(ctx.app_handle(), &request))
        .setup(|app| {
            let on_top = app.state::<Mutex<App>>().lock().unwrap().store.config.always_on_top;
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
            selftest_requested,
            selftest_delete_session,
            selftest_done,
        ])
        .run(tauri::generate_context!())
        .expect("Snagbook could not start");
}
