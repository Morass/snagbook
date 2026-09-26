use chrono::{DateTime, Utc};
use snagbook_core::*;
use std::fs;
use std::path::Path;

struct Env {
    _dir: tempfile::TempDir,
    root: String,
    home: String,
}

fn env() -> Env {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().to_string_lossy().to_string();
    let root = dir.path().join("sessions").to_string_lossy().to_string();
    Env { _dir: dir, root, home }
}

fn date(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}

fn new(e: &Env) -> Session {
    Session::create_now(&e.root, &Config::default()).unwrap()
}

fn add(s: &mut Session) -> ItemRecord {
    s.add_item(None, Utc::now()).unwrap()
}

fn delete(s: &mut Session, id: i64) {
    s.delete_item(id, |p| fs::remove_dir_all(p).map_err(Into::into)).unwrap()
}

fn readme(s: &Session) -> String {
    fs::read_to_string(s.dir.join("README.md")).unwrap()
}

fn path(s: &Session) -> String {
    s.dir.to_string_lossy().to_string()
}

#[test]
fn create_makes_hash_date_folder_with_manifest_and_readme() {
    let e = env();
    let cfg = Config { header: "REVIEW {session}".into(), ..Config::default() };
    let s = Session::create(&e.root, &cfg, date("2026-09-24T10:00:00Z"), "ab12cd34").unwrap();
    let name = s.dir.file_name().unwrap().to_string_lossy().to_string();
    assert!(name.starts_with("ab12cd34_"));
    assert!(name.ends_with("-09-2026"));
    assert!(s.dir.join("session.json").is_file());
    assert!(readme(&s).starts_with(&format!("REVIEW {}\n", s.display_path)), "{}", readme(&s));
}

#[test]
fn session_json_is_what_the_macos_app_reads() {
    let e = env();
    let mut s = Session::create(&e.root, &Config::default(), date("2026-09-24T10:00:00.750Z"), "ab12cd34").unwrap();
    s.add_item(Some("Main menu"), date("2026-09-24T10:01:02Z")).unwrap();
    let json: serde_json::Value = serde_json::from_str(&fs::read_to_string(s.dir.join("session.json")).unwrap()).unwrap();
    assert_eq!(json["created"], "2026-09-24T10:00:00Z", "whole seconds, UTC: the macOS decoder refuses fractions");
    assert_eq!(json["format"], 1);
    assert_eq!(json["nextItem"], 2);
    assert_eq!(json["items"][0]["folder"], "01-main-menu");
    assert_eq!(json["items"][0]["created"], "2026-09-24T10:01:02Z");
    assert!(json.get("title").is_none() && json.get("header").is_none(), "unset keys are left out, as the macOS app does");
}

#[test]
fn opens_a_session_written_by_the_macos_app() {
    let e = env();
    let dir = Path::new(&e.root).join("ccf6f650_25-09-2026");
    fs::create_dir_all(dir.join("01-achievements")).unwrap();
    fs::write(dir.join("01-achievements/notes.md"), "---\ntitle: \"Achievements\"\ncreated: \"2026-09-25T18:03:59+02:00\"\n---\n\nLocked.\n").unwrap();
    fs::write(
        dir.join("session.json"),
        "{\n  \"created\" : \"2026-09-25T16:03:58Z\",\n  \"format\" : 1,\n  \"id\" : \"ccf6f650\",\n  \"items\" : [\n    {\n      \"created\" : \"2026-09-25T16:03:59Z\",\n      \"folder\" : \"01-achievements\",\n      \"id\" : 1,\n      \"title\" : \"Achievements\"\n    }\n  ],\n  \"nextItem\" : 2\n}",
    )
    .unwrap();
    let s = Session::open(&dir.to_string_lossy(), "h").unwrap();
    assert_eq!(s.manifest.items[0].title, "Achievements");
    assert_eq!(s.read_note(1).unwrap(), "Locked.\n");
    assert_eq!(Session::list(&e.root)[0].items, 1);
}

#[test]
fn same_minute_same_hash_does_not_collide() {
    let e = env();
    let a = Session::create(&e.root, &Config::default(), Utc::now(), "00000000").unwrap();
    let b = Session::create(&e.root, &Config::default(), Utc::now(), "00000000").unwrap();
    assert_ne!(a.dir, b.dir);
}

#[test]
fn items_default_names_rename_and_folders() {
    let e = env();
    let mut s = new(&e);
    let one = add(&mut s);
    let two = s.add_item(Some("Main menu"), Utc::now()).unwrap();
    assert_eq!(one.title, "Item 1");
    assert_eq!(one.folder, "01-item-1");
    assert_eq!(two.folder, "02-main-menu");
    let renamed = s.rename_item(1, "Inventory: drag & drop").unwrap();
    assert_eq!(renamed.folder, "01-inventory-drag-drop");
    assert!(!s.dir.join("01-item-1").exists());
    let note = fs::read_to_string(s.note_path(1).unwrap()).unwrap();
    assert!(note.contains("title: \"Inventory: drag & drop\""), "{note}");
    assert!(s.rename_item(1, "   ").is_err());
}

#[test]
fn deleting_from_the_end_gives_the_numbers_back() {
    let e = env();
    let mut s = new(&e);
    for _ in 0..4 {
        add(&mut s);
    }
    delete(&mut s, 2);
    assert_eq!(add(&mut s).id, 5, "1 3 4 → 5: a gap in the middle is not refilled");
    delete(&mut s, 5);
    delete(&mut s, 4);
    assert_eq!(add(&mut s).id, 4, "1 3 after deleting 4 and 5 → 4");
    assert_eq!(s.manifest.items.iter().map(|r| r.id).collect::<Vec<_>>(), [1, 3, 4]);
    assert_eq!(Session::open(&path(&s), "").unwrap().manifest.next_item, 5);
}

#[test]
fn deleting_everything_starts_again_at_one() {
    let e = env();
    let mut s = new(&e);
    add(&mut s);
    add(&mut s);
    delete(&mut s, 2);
    delete(&mut s, 1);
    assert_eq!(add(&mut s).id, 1);
}

#[test]
fn folder_removed_from_outside_at_the_end_gives_its_number_back() {
    let e = env();
    let mut s = new(&e);
    for _ in 0..3 {
        add(&mut s);
    }
    fs::remove_dir_all(s.item_dir(3).unwrap()).unwrap();
    let mut again = Session::open(&path(&s), "").unwrap();
    assert_eq!(add(&mut again).id, 3);
}

#[test]
fn a_numbered_folder_left_on_disk_keeps_its_number() {
    let e = env();
    let mut s = new(&e);
    add(&mut s);
    add(&mut s);
    s.delete_item(2, |p| {
        fs::remove_dir_all(p)?;
        fs::create_dir(p.parent().unwrap().join("02-left-behind"))?;
        Ok(())
    })
    .unwrap();
    assert_eq!(add(&mut s).id, 3, "02-left-behind is still there, so 2 is not reused");
}

#[test]
fn write_note_keeps_front_matter_and_updates_readme() {
    let e = env();
    let mut s = new(&e);
    s.add_item(Some("Main menu"), Utc::now()).unwrap();
    assert!(s.write_note(1, "Logo overlaps.\n\n![](media/shot-001.png)\n").unwrap());
    assert!(!s.write_note(1, "Logo overlaps.\n\n![](media/shot-001.png)\n").unwrap(), "unchanged write is skipped");
    let raw = fs::read_to_string(s.note_path(1).unwrap()).unwrap();
    assert!(raw.starts_with("---\ntitle: \"Main menu\"\ncreated: "), "{raw}");
    assert_eq!(s.read_note(1).unwrap(), "Logo overlaps.\n\n![](media/shot-001.png)\n");
    let r = readme(&s);
    assert!(r.contains("## 1. Main menu"), "{r}");
    assert!(r.contains("![](01-main-menu/media/shot-001.png)"), "{r}");
}

#[test]
fn hand_edited_front_matter_lines_survive() {
    let e = env();
    let mut s = new(&e);
    s.add_item(Some("A"), Utc::now()).unwrap();
    fs::write(s.note_path(1).unwrap(), "---\ntitle: \"A\"\nstatus: resolved\n---\n\nbody\n").unwrap();
    s.write_note(1, "new body\n").unwrap();
    s.rename_item(1, "B").unwrap();
    assert_eq!(fs::read_to_string(s.note_path(1).unwrap()).unwrap(), "---\ntitle: \"B\"\nstatus: resolved\n---\n\nnew body\n");
}

#[test]
fn media_names_count_up_and_skip_companions() {
    let e = env();
    let mut s = new(&e);
    add(&mut s);
    assert_eq!(s.save_media(1, &[1], "shot", "PNG").unwrap(), "media/shot-001.png");
    fs::write(s.media_dir(1).unwrap().join("shot-002.orig.png"), [1]).unwrap();
    assert_eq!(s.save_media(1, &[1], "shot", "png").unwrap(), "media/shot-003.png");
    let (rel, p) = s.reserve_media_name(1, "clip", "mp4").unwrap();
    assert_eq!(rel, "media/clip-001.mp4");
    fs::write(p, [0]).unwrap();
    assert_eq!(s.media_count(1), MediaCount { images: 2, videos: 1 });
}

#[test]
fn open_repairs_folders_removed_or_added_by_hand() {
    let e = env();
    let mut s = new(&e);
    s.add_item(Some("Keep"), Utc::now()).unwrap();
    s.add_item(Some("Gone"), Utc::now()).unwrap();
    fs::remove_dir_all(s.item_dir(2).unwrap()).unwrap();
    let manual = s.dir.join("07-by-hand");
    fs::create_dir_all(&manual).unwrap();
    fs::write(manual.join("notes.md"), "---\ntitle: \"By hand\"\n---\n\nx\n").unwrap();
    let mut again = Session::open(&path(&s), "").unwrap();
    assert_eq!(again.manifest.items.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(), ["Keep", "By hand"]);
    assert_eq!(add(&mut again).id, 8);
}

#[test]
fn list_newest_first_and_ignores_strangers() {
    let e = env();
    Session::create(&e.root, &Config::default(), date("2026-01-01T00:00:00Z"), "11111111").unwrap();
    Session::create(&e.root, &Config::default(), date("2026-02-01T00:00:00Z"), "22222222").unwrap();
    fs::create_dir_all(Path::new(&e.root).join("not-a-session")).unwrap();
    let l = Session::list(&e.root);
    assert_eq!(l.len(), 2);
    assert!(l[0].path.contains("22222222"));
}

#[test]
fn a_session_deleted_from_outside_drops_out_of_the_list() {
    let e = env();
    let a = new(&e);
    let _b = new(&e);
    fs::remove_dir_all(&a.dir).unwrap();
    assert_eq!(Session::list(&e.root).len(), 1);
    assert!(!a.exists());
}

#[test]
fn a_session_deleted_from_outside_is_never_recreated_by_a_write() {
    let e = env();
    let mut s = new(&e);
    add(&mut s);
    fs::remove_dir_all(&s.dir).unwrap();
    assert!(s.write_note(1, "x").is_err());
    assert!(s.save_media(1, &[1], "shot", "png").is_err());
    assert!(s.add_item(None, Utc::now()).is_err());
    assert!(!s.dir.exists(), "the folder came back");
    assert!(Session::list(&e.root).is_empty());
}

#[test]
fn open_rejects_a_folder_without_manifest() {
    let e = env();
    assert_eq!(Session::open(&e.home, "").err(), Some(SnagError::NotASession(e.home.clone())));
}

#[test]
fn handoff_styles() {
    let e = env();
    let cfg = Config { header: "Please read {readme}".into(), ..Config::default() };
    let mut s = Session::create_now(&e.root, &cfg).unwrap();
    assert_eq!(s.handoff(HandoffStyle::Path), format!("{}/README.md", s.display_path));
    assert_eq!(s.handoff(HandoffStyle::Header), format!("Please read {}/README.md", s.display_path));
    s.set_header(Some("No placeholder")).unwrap();
    assert_eq!(s.handoff(HandoffStyle::Header), format!("No placeholder\n\n{}/README.md", s.display_path));
}

#[test]
fn sessions_follow_the_global_header_until_given_their_own() {
    let e = env();
    let cfg = Config { header: "old {session}".into(), ..Config::default() };
    let mut s = Session::create_now(&e.root, &cfg).unwrap();
    s.set_fallback_header("new header");
    assert!(readme(&s).starts_with("new header\n"));
    assert!(Session::open(&path(&s), "from settings").unwrap().handoff(HandoffStyle::Header).starts_with("from settings"));
    s.set_header(Some("mine")).unwrap();
    s.set_fallback_header("ignored");
    assert!(readme(&s).starts_with("mine\n"));
    assert_eq!(Session::open(&path(&s), "x").unwrap().manifest.header.as_deref(), Some("mine"));
    s.set_header(None).unwrap();
    assert!(readme(&s).starts_with("ignored\n"));
}

#[test]
fn session_names_default_to_their_start_and_show_in_the_list() {
    let e = env();
    let mut s = Session::create(&e.root, &Config::default(), date("2026-09-24T18:30:00Z"), "abcdabcd").unwrap();
    assert!(s.title().starts_with("Session 24 Sep, ") || s.title().starts_with("Session 25 Sep, "), "{}", s.title());
    s.set_title("  Inventory pass ").unwrap();
    assert_eq!(Session::open(&path(&s), "").unwrap().title(), "Inventory pass");
    assert_eq!(Session::list(&e.root)[0].title, "Inventory pass");
    assert!(readme(&s).contains("Session: **Inventory pass**"));
    s.set_title("").unwrap();
    assert!(s.title().starts_with("Session 2"));
}

#[test]
fn move_item() {
    let e = env();
    let mut s = new(&e);
    add(&mut s);
    add(&mut s);
    add(&mut s);
    s.move_item(3, 0).unwrap();
    assert_eq!(s.manifest.items.iter().map(|r| r.id).collect::<Vec<_>>(), [3, 1, 2]);
    assert!(readme(&s).contains("## 1. Item 3"));
}

#[test]
fn delete_without_trash_deletes_permanently_when_confirmed() {
    let e = env();
    let mut s = new(&e);
    let rec = s.add_item(Some("New"), Utc::now()).unwrap();
    let dir = s.item_dir(rec.id).unwrap();
    let mut asked = 0;
    s.delete_item(rec.id, Session::trash_or_delete(|_| Err(SnagError::NoTrash), |_| { asked += 1; true })).unwrap();
    assert_eq!(asked, 1);
    assert!(!dir.exists());
    assert!(Session::open(&path(&s), "").unwrap().manifest.items.is_empty());
}

#[test]
fn delete_without_trash_keeps_the_item_when_declined() {
    let e = env();
    let mut s = new(&e);
    let rec = s.add_item(Some("New"), Utc::now()).unwrap();
    let dir = s.item_dir(rec.id).unwrap();
    let r = s.delete_item(rec.id, Session::trash_or_delete(|_| Err(SnagError::NoTrash), |_| false));
    assert_eq!(r, Err(SnagError::Cancelled));
    assert!(dir.exists());
    assert_eq!(Session::open(&path(&s), "").unwrap().manifest.items.len(), 1);
}

#[test]
fn delete_that_trashes_never_asks() {
    let e = env();
    let mut s = new(&e);
    let rec = s.add_item(Some("New"), Utc::now()).unwrap();
    let mut trashed = None;
    s.delete_item(rec.id, Session::trash_or_delete(|p| { trashed = Some(p.to_path_buf()); Ok(()) }, |_| panic!("asked although the Trash worked"))).unwrap();
    assert_eq!(trashed.unwrap().file_name().unwrap(), "01-new");
}

/// Writes a session for the macOS app to open (see the interop check in the hub's notes):
/// `SNAG_INTEROP_OUT=<dir> cargo test -p snagbook-core -- --ignored interop`.
#[test]
#[ignore]
fn interop_write_a_session_for_the_macos_app() {
    let Ok(out) = std::env::var("SNAG_INTEROP_OUT") else { return };
    let mut s = Session::create(&out, &Config::default(), date("2026-09-26T10:00:00Z"), "d35c7070").unwrap();
    s.set_title("Made on Linux").unwrap();
    s.add_item(Some("Main menu: logo"), date("2026-09-26T10:01:00Z")).unwrap();
    s.add_item(Some("Příliš žluťoučký kůň"), date("2026-09-26T10:02:00Z")).unwrap();
    s.write_note(1, "**Bug:** the logo overlaps.\n\n![](media/shot-001.png)\n").unwrap();
    s.save_media(1, b"\x89PNG not really", "shot", "png").unwrap();
    s.delete_item(2, |p| std::fs::remove_dir_all(p).map_err(Into::into)).unwrap();
    s.add_item(Some("Third"), date("2026-09-26T10:03:00Z")).unwrap();
    println!("{}", s.dir.display());
}

/// Reads a session the macOS app wrote: `SNAG_INTEROP_IN=<session dir> cargo test ... -- --ignored interop`.
#[test]
#[ignore]
fn interop_read_a_session_from_the_macos_app() {
    let Ok(dir) = std::env::var("SNAG_INTEROP_IN") else { return };
    let mut s = Session::open(&dir, "h").unwrap();
    let titles: Vec<_> = s.manifest.items.iter().map(|r| r.title.clone()).collect();
    println!("titles={titles:?} next={}", s.manifest.next_item);
    let ids: Vec<i64> = s.manifest.items.iter().map(|r| r.id).collect();
    assert!(ids.iter().any(|id| s.read_note(*id).unwrap().contains("from the Mac")), "a note written on the Mac reads back");
    let added = s.add_item(Some("Added on Linux"), Utc::now()).unwrap();
    assert_eq!(added.id, s.manifest.items.iter().map(|r| r.id).max().unwrap());
    s.write_note(added.id, "written by the desktop app\n").unwrap();
}
