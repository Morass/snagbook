use crate::frontmatter::FrontMatter;
use crate::{render_header, Config, HandoffStyle, Naming, Paths, Result, SnagError};
use chrono::{DateTime, Local, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const MANIFEST_NAME: &str = "session.json";
pub const README_NAME: &str = "README.md";
pub const NOTE_NAME: &str = "notes.md";
pub const MEDIA_NAME: &str = "media";

/// Dates in session.json: whole seconds in UTC, as the macOS app writes and reads them.
mod stamp {
    use super::*;
    pub fn serialize<S: Serializer>(d: &DateTime<Utc>, s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&d.to_rfc3339_opts(SecondsFormat::Secs, true))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<DateTime<Utc>, D::Error> {
        let s = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&s).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemRecord {
    #[serde(with = "stamp")]
    pub created: DateTime<Utc>,
    pub folder: String,
    /// Prefixes the folder name. The next item takes the number after the highest one.
    pub id: i64,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    #[serde(with = "stamp")]
    pub created: DateTime<Utc>,
    #[serde(default = "one")]
    pub format: i64,
    /// This session's own header, placeholders unfilled. None: follow the global header.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub id: String,
    /// Display order.
    pub items: Vec<ItemRecord>,
    #[serde(rename = "nextItem")]
    pub next_item: i64,
    /// A name the user gave the session; None until then.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

fn one() -> i64 {
    1
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Summary {
    pub path: String,
    pub title: String,
    pub created: DateTime<Utc>,
    pub items: usize,
    #[serde(rename = "firstTitles")]
    pub first_titles: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
pub struct MediaCount {
    pub images: usize,
    pub videos: usize,
}

/// Write through a temporary file beside the target, so a reader never sees half a file.
pub(crate) fn write_atomic(path: &Path, data: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| SnagError::Io(format!("{} has no folder", path.display())))?;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.{:08x}.tmp", rand::random::<u32>()));
    fs::write(&tmp, data)?;
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(e.into());
    }
    Ok(())
}

fn iso_local(d: DateTime<Utc>) -> String {
    d.with_timezone(&Local).to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn names_in(dir: &Path) -> Vec<String> {
    fs::read_dir(dir)
        .map(|r| r.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default()
}

/// One test session: a folder holding session.json, README.md and a folder per item.
#[derive(Clone)]
pub struct FolderIdentity(Arc<same_file::Handle>);

pub struct Session {
    pub dir: PathBuf,
    /// How to spell the folder for people and other programs ("~/…").
    pub display_path: String,
    pub manifest: Manifest,
    pub open_token: String,
    fallback_header: String,
    folder_identity: FolderIdentity,
}

impl Session {
    // ------------------------------------------------------------ create / open / list

    /// Make a new session folder under `root` (e.g. "~/Snagbook").
    pub fn create(root: &str, config: &Config, now: DateTime<Utc>, hash: &str) -> Result<Session> {
        let root_dir = Paths::path(root);
        fs::create_dir_all(&root_dir)?;
        let base = Naming::session_folder(&config.folder_format, &now.with_timezone(&Local), hash);
        let mut name = base.clone();
        let mut n = 2;
        while root_dir.join(&name).exists() {
            name = format!("{base}-{n}");
            n += 1;
        }
        let dir = root_dir.join(&name);
        fs::create_dir(&dir)?;
        let dir = fs::canonicalize(dir)?;
        let display = format!("{}/{}", root.trim_end_matches('/'), name);
        let s = Session {
            folder_identity: FolderIdentity(Arc::new(same_file::Handle::from_path(&dir)?)),
            dir,
            display_path: Paths::abbreviate(&Paths::expand(&display)),
            manifest: Manifest { created: trunc(now), format: 1, header: None, id: hash.into(), items: vec![], next_item: 1, title: None },
            open_token: uuid::Uuid::new_v4().to_string(),
            fallback_header: config.header.clone(),
        };
        s.save_new()?;
        Ok(s)
    }

    pub fn create_now(root: &str, config: &Config) -> Result<Session> {
        Self::create(root, config, Utc::now(), &Naming::random_hash())
    }

    /// Open an existing session folder. `path` may use "~".
    pub fn open(path: &str, fallback_header: &str) -> Result<Session> {
        let requested = Paths::path(path);
        let dir = fs::canonicalize(&requested).map_err(|_| SnagError::NotASession(path.into()))?;
        let data = fs::read(dir.join(MANIFEST_NAME)).map_err(|_| SnagError::NotASession(path.into()))?;
        let manifest: Manifest = serde_json::from_slice(&data).map_err(|e| SnagError::Io(format!("{path}: {e}")))?;
        let folder_identity = FolderIdentity(Arc::new(same_file::Handle::from_path(&dir)?));
        let mut s = Session { dir, display_path: Paths::abbreviate(&Paths::expand(path)), manifest, open_token: uuid::Uuid::new_v4().to_string(), fallback_header: fallback_header.into(), folder_identity };
        s.repair();
        Ok(s)
    }

    /// Sessions under `root`, newest first. Folders without a session.json are ignored.
    pub fn list(root: &str) -> Vec<Summary> {
        let root_dir = Paths::path(root);
        let mut out = vec![];
        for name in names_in(&root_dir) {
            if name.starts_with('.') {
                continue;
            }
            let Ok(d) = fs::read(root_dir.join(&name).join(MANIFEST_NAME)) else { continue };
            let Ok(m) = serde_json::from_slice::<Manifest>(&d) else { continue };
            let display = format!("{}/{}", root.trim_end_matches('/'), name);
            out.push(Summary {
                path: Paths::abbreviate(&Paths::expand(&display)),
                title: m.title.clone().unwrap_or_else(|| Self::default_title(m.created)),
                created: m.created,
                items: m.items.len(),
                first_titles: m.items.iter().take(3).map(|i| i.title.clone()).collect(),
            });
        }
        out.sort_by(|a, b| b.created.cmp(&a.created));
        out
    }

    /// Whether the folder is still there (it can be deleted from outside at any time).
    pub fn exists(&self) -> bool {
        self.dir.is_dir() && self.dir.join(MANIFEST_NAME).is_file() && self.matches_folder_identity(&self.folder_identity)
    }

    pub fn matches_disk_identity(&self) -> bool {
        let same_folder = self.matches_folder_identity(&self.folder_identity);
        same_folder && fs::read(self.dir.join(MANIFEST_NAME))
            .ok()
            .and_then(|data| serde_json::from_slice::<Manifest>(&data).ok())
            .is_some_and(|disk| disk.id == self.manifest.id)
    }

    pub fn folder_identity(&self) -> FolderIdentity {
        self.folder_identity.clone()
    }

    pub fn matches_folder_identity(&self, expected: &FolderIdentity) -> bool {
        same_file::Handle::from_path(&self.dir).ok().is_some_and(|current| current == *expected.0)
    }

    /// Folders may have been renamed or removed by hand: drop records whose folder is gone,
    /// and adopt item folders that exist on disk but are missing from the manifest.
    fn repair(&mut self) {
        let before = self.manifest.items.len();
        let dir = self.dir.clone();
        self.manifest.items.retain(|r| dir.join(&r.folder).exists());
        let mut changed = self.manifest.items.len() != before;
        let known: HashSet<String> = self.manifest.items.iter().map(|r| r.folder.clone()).collect();
        let mut names = names_in(&self.dir);
        names.sort();
        for name in names {
            if known.contains(&name) {
                continue;
            }
            let Some(num) = Naming::folder_number(&name) else { continue };
            let note = self.dir.join(&name).join(NOTE_NAME);
            if !note.is_file() || self.manifest.items.iter().any(|r| r.id == num) {
                continue;
            }
            let text = fs::read_to_string(&note).unwrap_or_default();
            let title = FrontMatter::split(&text).fields.into_iter().find(|(k, _)| k == "title").map(|(_, v)| v).unwrap_or_else(|| name.clone());
            self.manifest.items.push(ItemRecord { created: trunc(Utc::now()), folder: name, id: num, title });
            self.manifest.next_item = self.manifest.next_item.max(num + 1);
            changed = true;
        }
        let next = self.manifest.next_item;
        self.settle_next_item();
        changed |= self.manifest.next_item != next;
        if changed {
            let _ = self.save();
        }
    }

    /// The next item takes the number after the highest remaining one, so deleting from the
    /// end gives the numbers back (1 3 4 → 5; delete 4 → 4). A numbered folder still on disk
    /// keeps its number.
    fn settle_next_item(&mut self) {
        let taken: HashSet<i64> = names_in(&self.dir)
            .iter()
            .filter_map(|n| n.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().ok())
            .collect();
        let mut n = self.manifest.items.iter().map(|r| r.id).max().unwrap_or(0) + 1;
        while taken.contains(&n) {
            n += 1;
        }
        self.manifest.next_item = n;
    }

    // ------------------------------------------------------------ items

    pub fn item(&self, id: i64) -> Result<&ItemRecord> {
        self.manifest.items.iter().find(|r| r.id == id).ok_or(SnagError::NoSuchItem(id))
    }

    pub fn item_dir(&self, id: i64) -> Result<PathBuf> {
        Ok(self.dir.join(&self.item(id)?.folder))
    }

    pub fn note_path(&self, id: i64) -> Result<PathBuf> {
        Ok(self.item_dir(id)?.join(NOTE_NAME))
    }

    pub fn media_dir(&self, id: i64) -> Result<PathBuf> {
        Ok(self.item_dir(id)?.join(MEDIA_NAME))
    }

    /// Add an item after the others. With no title it is "Item N".
    pub fn add_item(&mut self, title: Option<&str>, now: DateTime<Utc>) -> Result<ItemRecord> {
        self.require_exists()?;
        let id = self.manifest.next_item;
        let t = title.map(str::trim).filter(|t| !t.is_empty()).map(String::from).unwrap_or_else(|| format!("Item {id}"));
        let folder = Naming::item_folder(id, &t);
        let dir = self.dir.join(&folder);
        if !self.dir.is_dir() {
            return Err(SnagError::Io(format!("The session folder {} is gone.", self.display_path)));
        }
        if !dir.is_dir() {
            fs::create_dir(&dir)?;
        }
        let now = trunc(now);
        let record = ItemRecord { created: now, folder, id, title: t.clone() };
        let note = FrontMatter::join("", &[("title", &t), ("created", &iso_local(now))], "");
        write_atomic(&dir.join(NOTE_NAME), note.as_bytes())?;
        self.manifest.items.push(record.clone());
        self.manifest.next_item = id + 1;
        self.save()?;
        Ok(record)
    }

    /// Rename an item: its title, its note's front matter and its folder name.
    pub fn rename_item(&mut self, id: i64, title: &str) -> Result<ItemRecord> {
        self.retitle_item(id, title, true)
    }

    /// Change an item's title; its folder follows only when `move_folder` is set (not while
    /// files are being written into it). Called again with the same title and `move_folder`,
    /// it brings a folder left behind up to date.
    pub fn retitle_item(&mut self, id: i64, title: &str, move_folder: bool) -> Result<ItemRecord> {
        self.require_exists()?;
        let t = title.trim().to_string();
        if t.is_empty() {
            return Err(SnagError::BadName(title.into()));
        }
        let i = self.manifest.items.iter().position(|r| r.id == id).ok_or(SnagError::NoSuchItem(id))?;
        let mut rec = self.manifest.items[i].clone();
        let new_folder = Naming::item_folder(id, &t);
        if rec.title == t && (!move_folder || new_folder == rec.folder || self.dir.join(&new_folder).exists()) {
            return Ok(rec);
        }
        if move_folder && new_folder != rec.folder {
            let to = self.dir.join(&new_folder);
            if !to.exists() {
                fs::rename(self.dir.join(&rec.folder), &to)?;
                rec.folder = new_folder;
            }
        }
        rec.title = t.clone();
        self.manifest.items[i] = rec.clone();
        let note = self.dir.join(&rec.folder).join(NOTE_NAME);
        let text = fs::read_to_string(&note).unwrap_or_default();
        let parts = FrontMatter::split(&text);
        write_atomic(&note, FrontMatter::join(&parts.raw, &[("title", &t)], &parts.body).as_bytes())?;
        self.save()?;
        Ok(rec)
    }

    /// Remove an item. `discard` decides what happens to the folder (the app moves it to
    /// the Trash); an error from it leaves the item in place.
    pub fn delete_item(&mut self, id: i64, discard: impl FnOnce(&Path) -> Result<()>) -> Result<()> {
        self.require_exists()?;
        let dir = self.item_dir(id)?;
        discard(&dir)?;
        self.manifest.items.retain(|r| r.id != id);
        self.settle_next_item();
        self.save()
    }

    /// Remove the whole session using the front end's Trash policy.
    pub fn delete(&self, discard: impl FnOnce(&Path) -> Result<()>) -> Result<()> {
        self.require_exists()?;
        discard(&self.dir)
    }

    /// A `discard` for delete_item: move the folder to the Trash, and when its drive has none
    /// delete it outright only if `delete_permanently` agrees. Declining is `Cancelled`.
    pub fn trash_or_delete<'a>(
        trash: impl FnOnce(&Path) -> Result<()> + 'a,
        delete_permanently: impl FnOnce(&Path) -> bool + 'a,
    ) -> impl FnOnce(&Path) -> Result<()> + 'a {
        move |p: &Path| match trash(p) {
            Err(SnagError::NoTrash) => {
                if !delete_permanently(p) {
                    return Err(SnagError::Cancelled);
                }
                fs::remove_dir_all(p).map_err(Into::into)
            }
            other => other,
        }
    }

    pub fn move_item(&mut self, id: i64, index: usize) -> Result<()> {
        self.require_exists()?;
        let from = self.manifest.items.iter().position(|r| r.id == id).ok_or(SnagError::NoSuchItem(id))?;
        let rec = self.manifest.items.remove(from);
        let to = index.min(self.manifest.items.len());
        self.manifest.items.insert(to, rec);
        self.save()
    }

    // ------------------------------------------------------------ session name and header

    /// The session's name: what the user called it, or when it started.
    pub fn title(&self) -> String {
        self.manifest.title.clone().unwrap_or_else(|| Self::default_title(self.manifest.created))
    }

    pub fn default_title(created: DateTime<Utc>) -> String {
        format!("Session {}", created.with_timezone(&Local).format("%-d %b, %H:%M"))
    }

    /// Name the session; an empty name goes back to the date.
    pub fn set_title(&mut self, title: &str) -> Result<()> {
        self.require_exists()?;
        let t = title.trim();
        self.manifest.title = if t.is_empty() { None } else { Some(t.into()) };
        self.save()
    }

    /// Give this session its own header; None goes back to the global one.
    pub fn set_header(&mut self, header: Option<&str>) -> Result<()> {
        self.require_exists()?;
        self.manifest.header = header.map(String::from);
        self.save()
    }

    pub fn fallback_header(&self) -> &str {
        &self.fallback_header
    }

    /// The header used when the session has none of its own (the global setting).
    pub fn set_fallback_header(&mut self, h: &str) {
        if self.fallback_header == h {
            return;
        }
        self.fallback_header = h.into();
        if self.manifest.header.is_none() {
            let _ = self.write_readme();
        }
    }

    // ------------------------------------------------------------ notes

    /// The note's Markdown without its front matter.
    pub fn read_note(&self, id: i64) -> Result<String> {
        let text = fs::read_to_string(self.note_path(id)?)?;
        Ok(FrontMatter::split(&text).body)
    }

    /// Store the note's Markdown, keeping its front matter. False when the file already held
    /// exactly this.
    pub fn write_note(&mut self, id: i64, body: &str) -> Result<bool> {
        self.require_exists()?;
        let path = self.note_path(id)?;
        if !path.parent().is_some_and(Path::is_dir) {
            return Err(SnagError::Io(format!("The folder of item {id} is gone.")));
        }
        let old = fs::read_to_string(&path)?;
        let parts = FrontMatter::split(&old);
        let rec = self.item(id)?.clone();
        let created = iso_local(rec.created);
        let updates: Vec<(&str, &str)> = if parts.fields.is_empty() { vec![("title", &rec.title), ("created", &created)] } else { vec![] };
        let new = FrontMatter::join(&parts.raw, &updates, body);
        if new == old {
            return Ok(false);
        }
        write_atomic(&path, new.as_bytes())?;
        self.write_readme()?;
        Ok(true)
    }

    // ------------------------------------------------------------ media

    /// Save bytes into the item's media folder under the next free "prefix-NNN.ext".
    /// Returns the path relative to the item folder ("media/shot-001.png").
    pub fn save_media(&self, id: i64, data: &[u8], prefix: &str, ext: &str) -> Result<String> {
        let (rel, path) = self.reserve_media_name(id, prefix, ext)?;
        write_atomic(&path, data)?;
        Ok(rel)
    }

    /// A free name in the item's media folder, for a file that will be written later.
    pub fn reserve_media_name(&self, id: i64, prefix: &str, ext: &str) -> Result<(String, PathBuf)> {
        self.require_exists()?;
        let item = self.item_dir(id)?;
        if !item.is_dir() {
            return Err(SnagError::Io(format!("The folder of item {id} is gone.")));
        }
        let media = item.join(MEDIA_NAME);
        if !media.is_dir() {
            fs::create_dir(&media)?;
        }
        let existing: HashSet<String> = names_in(&media).into_iter().collect();
        let name = Naming::next_media_name(prefix, &ext.to_lowercase(), &existing);
        Ok((format!("{MEDIA_NAME}/{name}"), media.join(name)))
    }

    pub fn media_count(&self, id: i64) -> MediaCount {
        let mut c = MediaCount::default();
        let Ok(media) = self.media_dir(id) else { return c };
        for n in names_in(&media) {
            let l = n.to_lowercase();
            if l.ends_with(".orig.png") {
                continue;
            }
            if [".png", ".jpg", ".jpeg", ".gif", ".heic", ".tiff", ".webp"].iter().any(|e| l.ends_with(e)) {
                c.images += 1;
            }
            if [".mp4", ".mov", ".m4v", ".webm"].iter().any(|e| l.ends_with(e)) {
                c.videos += 1;
            }
        }
        c
    }

    // ------------------------------------------------------------ README and hand-off

    pub fn rendered_header(&self) -> String {
        let h = self.manifest.header.as_deref().unwrap_or(&self.fallback_header);
        render_header(h, &self.display_path, self.manifest.created, self.manifest.items.len())
    }

    /// README.md: the header, then every item's note with its links pointing into the item's
    /// folder, so one file is the whole session.
    pub fn readme_text(&self) -> String {
        let mut out = format!("{}\n", self.rendered_header().trim());
        out.push_str("\n---\n\n");
        let n = self.manifest.items.len();
        out.push_str(&format!(
            "Session: **{}** · folder `{}` · started {} · {} item{}\n",
            self.title(),
            self.display_path,
            iso_local(self.manifest.created),
            n,
            if n == 1 { "" } else { "s" }
        ));
        for (i, rec) in self.manifest.items.iter().enumerate() {
            let body = self.read_note(rec.id).unwrap_or_default().trim().to_string();
            let c = self.media_count(rec.id);
            let mut media = vec![];
            if c.images > 0 {
                media.push(format!("{} image{}", c.images, if c.images == 1 { "" } else { "s" }));
            }
            if c.videos > 0 {
                media.push(format!("{} video{}", c.videos, if c.videos == 1 { "" } else { "s" }));
            }
            out.push_str(&format!("\n## {}. {}\n\n", i + 1, rec.title));
            out.push_str(&format!("Folder: [`{0}/`]({0}/{1})", rec.folder, NOTE_NAME));
            if !media.is_empty() {
                out.push_str(&format!(" · {}", media.join(", ")));
            }
            out.push_str("\n\n");
            if body.is_empty() {
                out.push_str("_(no notes)_\n");
            } else {
                out.push_str(&Self::rebase_links(&body, &rec.folder));
                out.push('\n');
            }
        }
        out
    }

    pub fn write_readme(&self) -> Result<()> {
        self.require_exists()?;
        let path = self.dir.join(README_NAME);
        let text = self.readme_text();
        if fs::read_to_string(&path).ok().as_deref() == Some(text.as_str()) {
            return Ok(());
        }
        write_atomic(&path, text.as_bytes())
    }

    /// What Copy Hand-off puts on the clipboard.
    pub fn handoff(&self, style: HandoffStyle) -> String {
        let readme = format!("{}/{}", self.display_path, README_NAME);
        match style {
            HandoffStyle::Path => readme,
            HandoffStyle::Header => {
                let h = self.rendered_header().trim().to_string();
                if h.contains(&self.display_path) {
                    h
                } else {
                    format!("{h}\n\n{readme}")
                }
            }
        }
    }

    /// Point a note's relative links (media/…) at the item folder, for README.md.
    pub fn rebase_links(body: &str, folder: &str) -> String {
        let mut s = body.to_string();
        for (a, b) in [("](media/", format!("]({folder}/media/")), ("src=\"media/", format!("src=\"{folder}/media/")), ("](./media/", format!("]({folder}/media/"))] {
            s = s.replace(a, &b);
        }
        s
    }

    // ------------------------------------------------------------ persistence

    fn save(&self) -> Result<()> {
        self.require_exists()?;
        self.save_new()
    }

    fn save_new(&self) -> Result<()> {
        write_atomic(&self.dir.join(MANIFEST_NAME), serde_json::to_string_pretty(&self.manifest)?.as_bytes())?;
        self.write_readme()
    }

    fn require_exists(&self) -> Result<()> {
        if self.matches_disk_identity() { Ok(()) } else { Err(SnagError::Io(format!("The session folder {} is gone or was replaced.", self.display_path))) }
    }
}

fn trunc(d: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp(d.timestamp(), 0).unwrap_or(d)
}
