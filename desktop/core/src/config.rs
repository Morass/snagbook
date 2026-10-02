use crate::{Result, SnagError};
use serde::{Deserialize, Deserializer, Serialize};
use std::path::{Path, PathBuf};

/// A button on the template bar: one click types `body` at the caret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Template {
    pub body: String,
    #[serde(default)]
    pub icon: String,
    #[serde(default = "new_id")]
    pub id: String,
    pub label: String,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

impl Template {
    pub fn new(label: &str, icon: &str, body: &str) -> Self {
        Template { body: body.into(), icon: icon.into(), id: new_id(), label: label.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CaptureSettings {
    /// Open the mark-up window after a screenshot taken with Snagbook.
    pub annotate_screenshots: bool,
    /// Frames per second of a recording.
    pub fps: i64,
    /// Longest side of a recording in pixels; bigger regions are scaled down.
    pub max_long_edge: i64,
    /// Still frames written beside each video, one per second up to this many.
    pub max_stills: i64,
    pub show_cursor: bool,
    pub system_audio: bool,
}

impl Default for CaptureSettings {
    fn default() -> Self {
        CaptureSettings { annotate_screenshots: true, fps: 15, max_long_edge: 1920, max_stills: 60, show_cursor: true, system_audio: false }
    }
}

impl CaptureSettings {
    /// Values a hand-edited file could get wrong, pulled back into range.
    pub fn sanitized(mut self) -> Self {
        self.fps = self.fps.clamp(1, 60);
        self.max_long_edge = self.max_long_edge.clamp(320, 7680);
        self.max_stills = self.max_stills.clamp(0, 600);
        self
    }
}

/// What Copy Hand-off puts on the clipboard.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum HandoffStyle {
    /// The header text, with the session's path filled in.
    #[default]
    Header,
    /// Only the path of the session's README.md.
    Path,
}

/// An unknown hand-off style in the file falls back to the default instead of failing.
fn lenient_handoff<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<HandoffStyle, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    Ok(serde_json::from_value(v).unwrap_or_default())
}

/// Keys that work while another app has focus. Empty means off. The macOS app keeps its
/// own; these are for Linux and Windows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Shortcuts {
    pub new_item: String,
    pub record: String,
    pub screenshot: String,
    pub show_notebook: String,
}

impl Default for Shortcuts {
    fn default() -> Self {
        Shortcuts { new_item: "Ctrl+Alt+N".into(), record: "Ctrl+Alt+R".into(), screenshot: "Ctrl+Alt+S".into(), show_notebook: "Ctrl+Alt+B".into() }
    }
}

/// Everything the user can set. The same keys as the macOS app, so one file format.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    /// Keep the notebook above other windows.
    pub always_on_top: bool,
    pub capture: CaptureSettings,
    /// Name of a new session's folder. Tokens: {hash} {yyyy} {MM} {dd} {HH} {mm}.
    pub folder_format: String,
    #[serde(deserialize_with = "lenient_handoff")]
    pub handoff: HandoffStyle,
    /// Text at the top of every session's README.md.
    pub header: String,
    /// The session that was open last, reopened on launch.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session: Option<String>,
    /// Where new sessions are created. `~` is the home folder.
    pub sessions_folder: String,
    pub shortcuts: Shortcuts,
    pub templates: Vec<Template>,
}

pub const DEFAULT_HEADER: &str = "These are notes from a test session. Each numbered folder is one finding: read its notes.md, and look at the screenshots and videos in its media/ folder. Every video has still frames (one per second) and a contact sheet beside it.\n\nSession: {session}";

impl Config {
    pub fn default_templates() -> Vec<Template> {
        vec![
            Template::new("Bug", "🐞", "**Bug:** "),
            Template::new("Expected", "", "\n\n**Expected:** \n\n**Actual:** "),
            Template::new("Steps", "", "Steps to reproduce:\n\n1. "),
            Template::new("Idea", "💡", "**Idea:** "),
        ]
    }

    /// Same as another config, ignoring the random ids of default templates.
    pub fn same_as(&self, other: &Config) -> bool {
        let strip = |c: &Config| {
            let mut c = c.clone();
            for t in &mut c.templates {
                t.id.clear();
            }
            c
        };
        strip(self) == strip(other)
    }
}

impl Default for Config {
    fn default() -> Self {
        Config {
            always_on_top: false,
            capture: CaptureSettings::default(),
            folder_format: "{hash}_{dd}-{MM}-{yyyy}".into(),
            handoff: HandoffStyle::Header,
            header: DEFAULT_HEADER.into(),
            last_session: None,
            sessions_folder: "~/Snagbook".into(),
            shortcuts: Shortcuts::default(),
            templates: Config::default_templates(),
        }
    }
}

/// Reads and writes the settings file. A missing file is the defaults; a broken one is
/// reported and left alone (never overwritten with defaults behind the user's back).
pub struct ConfigStore {
    pub path: PathBuf,
    pub config: Config,
    /// Set when the file exists but could not be read; saving is refused until fixed.
    pub load_error: Option<String>,
}

impl ConfigStore {
    pub fn new(path: &Path) -> Self {
        let mut s = ConfigStore { path: path.to_path_buf(), config: Config::default(), load_error: None };
        s.reload();
        s
    }

    pub fn reload(&mut self) {
        self.load_error = None;
        let Ok(data) = std::fs::read(&self.path) else {
            self.config = Config::default();
            return;
        };
        match serde_json::from_slice::<Config>(&data) {
            Ok(mut c) => {
                c.capture = c.capture.sanitized();
                self.config = c;
            }
            Err(e) => {
                self.config = Config::default();
                self.load_error = Some(format!("{}: {e}", self.path.display()));
            }
        }
    }

    pub fn update(&mut self, change: impl FnOnce(&mut Config)) -> Result<()> {
        let mut c = self.config.clone();
        change(&mut c);
        if let Some(e) = &self.load_error {
            return Err(SnagError::ConfigUnreadable(e.clone()));
        }
        self.config = c;
        self.save()
    }

    pub fn save(&self) -> Result<()> {
        if let Some(e) = &self.load_error {
            return Err(SnagError::ConfigUnreadable(e.clone()));
        }
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        crate::session::write_atomic(&self.path, serde_json::to_string_pretty(&self.config)?.as_bytes())
    }
}
