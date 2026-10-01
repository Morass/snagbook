//! The mark-up window's side in the app: which picture it edits, and saving it in the
//! macOS app's format — `<name>.orig.png` (the untouched picture), `<name>.marks.json` (the
//! marks) and the drawn `<name>.png`.

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use snagbook_core::FolderIdentity;

pub const WINDOW: &str = "annotate";

#[derive(Clone)]
pub struct Pending {
    pub id: i64,
    pub rel: String,
    pub is_new: bool,
    pub session_id: String,
    pub session_path: String,
    pub session_dir: PathBuf,
    pub session_identity: FolderIdentity,
    pub item_dir: PathBuf,
    pub fallback_header: String,
    pub ack: Option<String>,
    /// The self-test's script for the page ("ring", "count", "clear", "skip").
    pub auto: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub id: i64,
    pub rel: String,
    pub is_new: bool,
    pub has_orig: bool,
    pub marks: Option<String>,
    pub auto: Option<String>,
}

/// "media/shot-001.png" -> ("media/shot-001.orig.png", "media/shot-001.marks.json").
pub fn companions(rel: &str) -> (String, String) {
    let stem = rel.strip_suffix(".png").unwrap_or(rel);
    (format!("{stem}.orig.png"), format!("{stem}.marks.json"))
}

pub struct Files {
    pub picture: PathBuf,
    pub orig: PathBuf,
    pub marks: PathBuf,
}

/// The three files for `rel` inside `item_dir`; None when `rel` is not an ordinary picture
/// inside the item.
pub fn files(item_dir: &Path, rel: &str) -> Option<Files> {
    let picture = crate::media::contained(item_dir, rel)?;
    let (o, m) = companions(rel);
    let dir = picture.parent()?.to_path_buf();
    let name = |r: &str| Path::new(r).file_name().map(|n| dir.join(n));
    Some(Files { picture, orig: name(&o)?, marks: name(&m)? })
}

pub fn info(f: &Files, p: &Pending) -> Info {
    Info {
        id: p.id,
        rel: p.rel.clone(),
        is_new: p.is_new,
        has_orig: f.orig.is_file(),
        marks: fs::read_to_string(&f.marks).ok(),
        auto: p.auto.clone(),
    }
}

/// A different temporary name for every write, even two at once in one process.
fn rand_suffix() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static N: AtomicU32 = AtomicU32::new(0);
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    t ^ N.fetch_add(0x9e37_79b9, Ordering::Relaxed) ^ std::process::id()
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension(format!("tmp{:08x}", rand_suffix()));
    fs::write(&tmp, data).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        e.to_string()
    })
}

/// Save a marked-up picture: keep the untouched original once, then write the drawing and
/// the marks. With nothing drawn, put the original back and drop the companions.
pub fn save(f: &Files, png: Option<&[u8]>, marks: Option<&str>) -> Result<(), String> {
    match (png, marks) {
        (Some(png), Some(marks)) => {
            if !png.starts_with(b"\x89PNG") {
                return Err("the drawing is not a PNG".into());
            }
            if !f.orig.is_file() {
                // Through a temporary file: a half-copied original would be trusted later and
                // the real one lost.
                let data = fs::read(&f.picture).map_err(|e| e.to_string())?;
                write_atomic(&f.orig, &data)?;
            }
            write_atomic(&f.picture, png)?;
            write_atomic(&f.marks, marks.as_bytes())
        }
        _ => {
            if f.orig.is_file() {
                fs::rename(&f.orig, &f.picture).map_err(|e| e.to_string())?;
            }
            let _ = fs::remove_file(&f.marks);
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let item = d.path().join("01-x");
        fs::create_dir_all(item.join("media")).unwrap();
        fs::write(item.join("media/shot-001.png"), b"\x89PNG original").unwrap();
        (d, item)
    }

    #[test]
    fn companion_names_match_the_macos_app() {
        assert_eq!(companions("media/shot-001.png"), ("media/shot-001.orig.png".into(), "media/shot-001.marks.json".into()));
        assert_eq!(companions("media/image-001.jpg"), ("media/image-001.jpg.orig.png".into(), "media/image-001.jpg.marks.json".into()));
    }

    #[test]
    fn the_original_is_kept_once_and_marks_can_be_removed_again() {
        let (_d, item) = item();
        let f = files(&item, "media/shot-001.png").unwrap();
        save(&f, Some(b"\x89PNG drawn 1"), Some("{\"marks\":[1]}")).unwrap();
        save(&f, Some(b"\x89PNG drawn 2"), Some("{\"marks\":[1,2]}")).unwrap();
        assert_eq!(fs::read(&f.orig).unwrap(), b"\x89PNG original", "the second save keeps the first original");
        assert_eq!(fs::read(&f.picture).unwrap(), b"\x89PNG drawn 2");
        assert!(fs::read_to_string(&f.marks).unwrap().contains("[1,2]"));
        save(&f, None, None).unwrap();
        assert_eq!(fs::read(&f.picture).unwrap(), b"\x89PNG original", "no marks: the original comes back");
        assert!(!f.orig.exists() && !f.marks.exists());
    }

    #[test]
    fn only_pictures_inside_the_item() {
        let (_d, item) = item();
        assert!(files(&item, "../01-x/media/shot-001.png").is_none());
        assert!(files(&item, "media/missing.png").is_none());
        let f = files(&item, "media/shot-001.png").unwrap();
        assert!(save(&f, Some(b"<html>"), Some("{}")).is_err(), "only a PNG is written over a picture");
    }
}
