use chrono::{DateTime, TimeZone, Utc};
use snagbook_core::*;
use std::collections::HashSet;

#[test]
fn slug() {
    assert_eq!(Naming::slug("Main menu: the Start button!"), "main-menu-the-start-button");
    assert_eq!(Naming::slug("Příliš žluťoučký kůň"), "prilis-zlutoucky-kun");
    assert_eq!(Naming::slug("🐞🐞"), "");
    assert_eq!(Naming::slug("ＦＵＬＬ width"), "full-width");
    let long = Naming::slug(&"abc ".repeat(30));
    assert!(long.len() <= 40);
    assert!(!long.ends_with('-'));
}

#[test]
fn item_folder() {
    assert_eq!(Naming::item_folder(3, "Item 3"), "03-item-3");
    assert_eq!(Naming::item_folder(120, "🐞"), "120");
}

#[test]
fn session_folder_format() {
    let d = Utc.with_ymd_and_hms(2026, 9, 4, 7, 5, 0).unwrap();
    assert_eq!(Naming::session_folder("{hash}_{dd}-{MM}-{yyyy}", &d, "deadbeef"), "deadbeef_04-09-2026");
    assert_eq!(Naming::session_folder("{yyyy}{MM}{dd}-{HH}{mm}/../x", &d, "h"), "20260904-0705-..-x");
    assert_eq!(Naming::session_folder("...", &d, "h"), "h");
    assert_eq!(Naming::session_folder("a<b>c|d?e*f\"g", &d, "h"), "a-b-c-d-e-f-g", "names Windows refuses");
}

#[test]
fn random_hash_shape() {
    let h = Naming::random_hash();
    assert_eq!(h.len(), 8);
    assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn paths_expand_and_abbreviate() {
    let home = Paths::home();
    let h = home.trim_end_matches('/');
    assert_eq!(Paths::expand("~/a/b"), format!("{h}/a/b"));
    assert_eq!(Paths::abbreviate(&format!("{h}/a/b")), "~/a/b");
    assert_eq!(Paths::abbreviate(&format!("{h}x/b")), format!("{h}x/b"), "a sibling with the same prefix is not inside home");
    assert_eq!(Paths::abbreviate("/tmp/x"), "/tmp/x");
}

#[test]
fn next_media_name_skips_companions() {
    let mut e: HashSet<String> = HashSet::new();
    assert_eq!(Naming::next_media_name("shot", "png", &e), "shot-001.png");
    e.insert("SHOT-001.PNG".into());
    e.insert("shot-002.orig.png".into());
    e.insert("shot-003-frames".into());
    assert_eq!(Naming::next_media_name("shot", "png", &e), "shot-004.png");
}

#[test]
fn front_matter_split_and_join() {
    let text = "---\ntitle: \"A \\\"quoted\\\" title\"\nstatus: open\n---\n\nBody\n";
    let p = FrontMatter::split(text);
    assert_eq!(p.fields.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(), ["title", "status"]);
    assert_eq!(p.fields[0].1, "A \"quoted\" title");
    assert_eq!(p.body, "Body\n");
    assert_eq!(FrontMatter::join(&p.raw, &[], &p.body), text);
}

#[test]
fn no_front_matter_is_all_body() {
    assert_eq!(FrontMatter::split("# Just text\n").body, "# Just text\n");
    assert_eq!(FrontMatter::split("---\nnot closed\n").body, "---\nnot closed\n");
    assert_eq!(FrontMatter::split("---\r\ntitle: x\r\n---\r\n\r\nWindows\r\n").body, "Windows\n");
}

#[test]
fn header_placeholders() {
    let d: DateTime<Utc> = Utc.with_ymd_and_hms(2026, 9, 24, 12, 0, 0).unwrap();
    let h = render_header("{session} {readme} {items} {date}", "~/s/x", d, 3);
    assert!(h.starts_with("~/s/x ~/s/x/README.md 3 2026-09-2"), "{h}");
}

// ---------------------------------------------------------------- config

fn cfg_path() -> (tempfile::TempDir, std::path::PathBuf) {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("sub/config.json");
    (d, p)
}

#[test]
fn missing_file_is_defaults_and_save_round_trips() {
    let (_d, p) = cfg_path();
    let mut store = ConfigStore::new(&p);
    assert!(store.config.same_as(&Config::default()));
    store.update(|c| {
        c.sessions_folder = "~/elsewhere".into();
        c.capture.fps = 30;
    })
    .unwrap();
    assert_eq!(ConfigStore::new(&p).config.sessions_folder, "~/elsewhere");
    assert_eq!(ConfigStore::new(&p).config.capture.fps, 30);
}

#[test]
fn partial_file_keeps_defaults_for_missing_keys() {
    let (_d, p) = cfg_path();
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(&p, r#"{"sessionsFolder":"~/x","capture":{"fps":500},"handoff":"carrier-pigeon"}"#).unwrap();
    let c = ConfigStore::new(&p).config;
    assert_eq!(c.sessions_folder, "~/x");
    assert_eq!(c.capture.fps, 60, "clamped");
    assert_eq!(c.capture.max_long_edge, 1920);
    assert_eq!(c.handoff, HandoffStyle::Header, "an unknown style falls back");
    assert_eq!(c.templates.iter().map(|t| t.label.as_str()).collect::<Vec<_>>(), ["Bug", "Expected", "Steps", "Idea"]);
}

#[test]
fn broken_file_is_never_overwritten() {
    let (_d, p) = cfg_path();
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(&p, "{ not json").unwrap();
    let mut store = ConfigStore::new(&p);
    assert!(store.load_error.is_some());
    assert!(store.update(|c| c.always_on_top = true).is_err());
    assert_eq!(std::fs::read_to_string(&p).unwrap(), "{ not json");
}

#[test]
fn reads_a_settings_file_written_by_the_macos_app() {
    let (_d, p) = cfg_path();
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(
        &p,
        r#"{
  "alwaysOnTop" : false,
  "capture" : { "annotateScreenshots" : true, "fps" : 15, "maxLongEdge" : 1920, "maxStills" : 60, "showCursor" : true, "systemAudio" : false },
  "folderFormat" : "{hash}_{dd}-{MM}-{yyyy}",
  "handoff" : "path",
  "header" : "REVIEW {session}",
  "lastSession" : "~/shared/abc_25-09-2026",
  "sessionsFolder" : "~/shared",
  "templates" : [ { "body" : "**Bug:** ", "icon" : "🐞", "id" : "0B7F5A58-9A0C-4C44-8C1E-0F1F2C8B9A11", "label" : "Bug" } ]
}"#,
    )
    .unwrap();
    let c = ConfigStore::new(&p).config;
    assert_eq!(c.handoff, HandoffStyle::Path);
    assert_eq!(c.last_session.as_deref(), Some("~/shared/abc_25-09-2026"));
    assert_eq!(c.templates[0].id, "0B7F5A58-9A0C-4C44-8C1E-0F1F2C8B9A11");
    assert_eq!(c.shortcuts.screenshot, "Ctrl+Alt+S", "a file without shortcuts gets the defaults");
}

#[test]
fn a_cleared_shortcut_stays_cleared() {
    let (_d, p) = cfg_path();
    let mut store = ConfigStore::new(&p);
    store.update(|c| c.shortcuts.new_item = String::new()).unwrap();
    let c = ConfigStore::new(&p).config;
    assert_eq!(c.shortcuts.new_item, "");
    assert_eq!(c.shortcuts.screenshot, "Ctrl+Alt+S");
}
