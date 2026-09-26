//! Serving an item's files to the editor: `snagbook://localhost/item/<id>/<path>` (on
//! Windows `http://snagbook.localhost/item/<id>/<path>`), with byte ranges so videos seek.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use tauri::http::{header, Request, Response, StatusCode};

/// File name prefix and extension for bytes pasted into a note.
pub fn name_for(mime: &str, name: &str) -> (&'static str, String) {
    let from_name = Path::new(name).extension().map(|e| e.to_string_lossy().to_lowercase()).filter(|e| !e.is_empty() && e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric()));
    if mime.starts_with("video/") {
        let ext = from_name.unwrap_or_else(|| match mime {
            "video/webm" => "webm".into(),
            "video/quicktime" => "mov".into(),
            _ => "mp4".into(),
        });
        return ("clip", ext);
    }
    let ext = match mime {
        "image/png" => "png".to_string(),
        "image/jpeg" => "jpg".into(),
        "image/gif" => "gif".into(),
        "image/webp" => "webp".into(),
        "image/bmp" => "bmp".into(),
        _ => from_name.unwrap_or_else(|| "png".into()),
    };
    ("image", ext)
}

/// `rel` resolved inside `dir`, or None when it would leave it (.., an absolute path, a
/// symlink pointing out) or is not an ordinary file.
pub fn contained(dir: &Path, rel: &str) -> Option<PathBuf> {
    let rel = rel.split(['?', '#']).next().unwrap_or("");
    let rel_path = Path::new(rel);
    if rel.is_empty() || rel_path.components().any(|c| !matches!(c, Component::Normal(_))) {
        return None;
    }
    let base = dir.canonicalize().ok()?;
    let full = base.join(rel_path).canonicalize().ok()?;
    if !full.starts_with(&base) || !full.is_file() {
        return None;
    }
    Some(full)
}

/// Whether a note's link may hand this file to the system: pictures, videos and documents,
/// never a program or a script.
pub fn openable(p: &Path) -> bool {
    let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    matches!(
        ext.as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "heic" | "tif" | "tiff" | "mp4" | "m4v" | "mov" | "webm" | "mkv"
            | "pdf" | "txt" | "md" | "log" | "csv" | "json"
    )
}

/// Largest piece of a file sent for one request: a video is read in pieces, not whole.
pub const MAX_PIECE: u64 = 8 * 1024 * 1024;

/// The range actually sent: at most MAX_PIECE bytes from `start`.
pub fn capped(start: u64, end: u64) -> (u64, u64) {
    (start, end.min(start + MAX_PIECE - 1))
}

fn content_type(p: &Path) -> &'static str {
    match p.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("svg") => "image/svg+xml",
        Some("mp4") | Some("m4v") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("webm") => "video/webm",
        Some("json") => "application/json",
        _ => "application/octet-stream",
    }
}

/// "bytes=a-b" against a file of `len` bytes: the inclusive range to send.
pub fn parse_range(value: &str, len: u64) -> Option<(u64, u64)> {
    let spec = value.trim().strip_prefix("bytes=")?;
    let (a, b) = spec.split(',').next()?.split_once('-')?;
    if len == 0 {
        return None;
    }
    let (start, end) = match (a.trim(), b.trim()) {
        ("", n) => {
            let n: u64 = n.parse().ok()?;
            (len.saturating_sub(n), len - 1)
        }
        (s, "") => (s.parse().ok()?, len - 1),
        (s, e) => (s.parse().ok()?, e.parse::<u64>().ok()?.min(len - 1)),
    };
    (start <= end && start < len).then_some((start, end))
}

/// Above this, a file asked for whole is sent in pieces rather than read into memory at once.
/// Pictures are asked for whole and cannot take a piece (a 12 MB screenshot would be cut off),
/// so the limit is far above any picture; only a long video is bigger, and players ask for
/// ranges.
pub const MAX_WHOLE: u64 = 256 * 1024 * 1024;

/// What to send for a request: None for the whole file, Some(None) for an unsatisfiable range,
/// Some(Some((start, end))) for a piece of at most MAX_PIECE bytes.
pub fn byte_range(header: Option<&str>, len: u64) -> Option<Option<(u64, u64)>> {
    match header.map(|v| parse_range(v, len)) {
        Some(Some((a, b))) => Some(Some(capped(a, b))),
        Some(None) => Some(None),
        None if len > MAX_WHOLE => Some(Some(capped(0, len - 1))),
        None => None,
    }
}

/// "/item/5/media/shot-001.png" -> (5, "media/shot-001.png")
pub fn parse_path(path: &str) -> Option<(i64, String)> {
    let decoded = percent_encoding::percent_decode_str(path).decode_utf8().ok()?.to_string();
    let rest = decoded.strip_prefix("/item/")?;
    let (id, rel) = rest.split_once('/')?;
    Some((id.parse().ok()?, rel.to_string()))
}

fn status(code: StatusCode) -> Response<Vec<u8>> {
    Response::builder().status(code).body(Vec::new()).unwrap()
}

pub fn serve(app: &tauri::AppHandle, request: &Request<Vec<u8>>) -> Response<Vec<u8>> {
    if request.uri().path() == "/capture/frame.png" {
        use tauri::Manager;
        let frozen = app.state::<crate::capture::Frozen>();
        let guard = frozen.0.lock().unwrap();
        return match guard.as_ref() {
            Some(f) => Response::builder().header(header::CONTENT_TYPE, "image/png").header(header::CACHE_CONTROL, "no-store").body(f.png.clone()).unwrap(),
            None => status(StatusCode::NOT_FOUND),
        };
    }
    let Some((id, rel)) = parse_path(request.uri().path()) else { return status(StatusCode::NOT_FOUND) };
    let Some(file) = crate::item_file(app, id, &rel) else { return status(StatusCode::NOT_FOUND) };
    let Ok(mut f) = File::open(&file) else { return status(StatusCode::NOT_FOUND) };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let kind = content_type(&file);
    let range = byte_range(request.headers().get(header::RANGE).and_then(|v| v.to_str().ok()), len);
    // The page's own origin differs from this scheme's; the files are the page's to read.
    let builder = Response::builder()
        .header(header::CONTENT_TYPE, kind)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "no-cache")
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*");
    match range {
        Some(None) => Response::builder().status(StatusCode::RANGE_NOT_SATISFIABLE).header(header::CONTENT_RANGE, format!("bytes */{len}")).body(Vec::new()).unwrap(),
        Some(Some((start, end))) => {
            let mut buf = vec![0; (end - start + 1) as usize];
            if f.seek(SeekFrom::Start(start)).and_then(|_| f.read_exact(&mut buf)).is_err() {
                return status(StatusCode::INTERNAL_SERVER_ERROR);
            }
            builder.status(StatusCode::PARTIAL_CONTENT).header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{len}")).body(buf).unwrap()
        }
        None => {
            let mut buf = Vec::with_capacity(len as usize);
            if f.read_to_end(&mut buf).is_err() {
                return status(StatusCode::INTERNAL_SERVER_ERROR);
            }
            builder.status(StatusCode::OK).body(buf).unwrap()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_for_pasted_bytes() {
        assert_eq!(name_for("image/png", ""), ("image", "png".into()));
        assert_eq!(name_for("image/jpeg", "x.jpeg"), ("image", "jpg".into()));
        assert_eq!(name_for("video/webm", ""), ("clip", "webm".into()));
        assert_eq!(name_for("video/mp4", "take.MOV"), ("clip", "mov".into()));
        assert_eq!(name_for("", "evil.png/../../x"), ("image", "png".into()), "a strange extension is not used");
    }

    #[test]
    fn contained_refuses_everything_outside_the_item() {
        let d = tempfile::tempdir().unwrap();
        let item = d.path().join("01-x");
        std::fs::create_dir_all(item.join("media")).unwrap();
        std::fs::write(item.join("media/shot-001.png"), [1]).unwrap();
        std::fs::write(d.path().join("secret.txt"), [1]).unwrap();
        assert!(contained(&item, "media/shot-001.png").is_some());
        assert!(contained(&item, "media/shot-001.png?v=2").is_some(), "a cache-busting query is not part of the name");
        assert!(contained(&item, "../secret.txt").is_none());
        assert!(contained(&item, "media/../../secret.txt").is_none());
        assert!(contained(&item, &d.path().join("secret.txt").to_string_lossy()).is_none());
        assert!(contained(&item, "media").is_none(), "a folder is not a file");
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(d.path().join("secret.txt"), item.join("media/link.png")).unwrap();
            assert!(contained(&item, "media/link.png").is_none(), "a symlink out of the item");
        }
    }

    #[test]
    fn ranges() {
        assert_eq!(parse_range("bytes=0-", 10), Some((0, 9)));
        assert_eq!(parse_range("bytes=2-4", 10), Some((2, 4)));
        assert_eq!(parse_range("bytes=5-100", 10), Some((5, 9)));
        assert_eq!(parse_range("bytes=-3", 10), Some((7, 9)));
        assert_eq!(parse_range("bytes=10-", 10), None);
        assert_eq!(parse_range("items=0-1", 10), None);
        assert_eq!(parse_range("bytes=0-1", 0), None);
    }

    #[test]
    fn only_media_and_documents_are_opened() {
        assert!(openable(Path::new("/s/01-x/media/clip-001.MP4")));
        assert!(openable(Path::new("/s/01-x/notes.md")));
        for bad in ["payload.exe", "run.bat", "x.sh", "x.desktop", "x.lnk", "x.ps1", "x.app", "noext"] {
            assert!(!openable(Path::new(bad)), "{bad}");
        }
    }

    #[test]
    fn a_large_file_asked_for_whole_is_served_in_pieces() {
        assert_eq!(byte_range(None, 1 << 30), Some(Some((0, MAX_PIECE - 1))), "no Range on a 1 GB video");
        assert_eq!(byte_range(Some("bytes=0-"), 1 << 30), Some(Some((0, MAX_PIECE - 1))));
        assert_eq!(byte_range(None, 1000), None, "a small picture is sent whole");
        assert_eq!(byte_range(None, 20 << 20), None, "a 20 MB picture is sent whole, not cut off at 8 MB");
        assert_eq!(byte_range(Some("bytes=5000-"), 1000), Some(None));
    }

    #[test]
    fn a_video_is_served_in_pieces() {
        assert_eq!(capped(0, 999), (0, 999));
        assert_eq!(capped(0, 1 << 30), (0, MAX_PIECE - 1), "bytes=0- on a 1 GB file");
        assert_eq!(capped(10, 20), (10, 20));
    }

    #[test]
    fn paths() {
        assert_eq!(parse_path("/item/5/media/shot-001.png"), Some((5, "media/shot-001.png".into())));
        assert_eq!(parse_path("/item/12/media/a%20b.png"), Some((12, "media/a b.png".into())));
        assert_eq!(parse_path("/other/5/x"), None);
        assert_eq!(parse_path("/item/x/y"), None);
    }
}
