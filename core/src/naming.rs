use chrono::{DateTime, Datelike, TimeZone, Timelike};
use std::collections::HashSet;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

pub struct Naming;

impl Naming {
    /// Eight hex characters.
    pub fn random_hash() -> String {
        format!("{:08x}", rand::random::<u32>())
    }

    /// Expand a session folder format such as "{hash}_{dd}-{MM}-{yyyy}".
    pub fn session_folder<Tz: TimeZone>(format: &str, date: &DateTime<Tz>, hash: &str) -> String {
        let f = if format.is_empty() { "{hash}_{dd}-{MM}-{yyyy}" } else { format };
        let s = f
            .replace("{hash}", hash)
            .replace("{yyyy}", &format!("{:04}", date.year()))
            .replace("{MM}", &format!("{:02}", date.month()))
            .replace("{dd}", &format!("{:02}", date.day()))
            .replace("{HH}", &format!("{:02}", date.hour()))
            .replace("{mm}", &format!("{:02}", date.minute()));
        Self::safe_file_name(&s, hash)
    }

    /// A file-name-safe spelling on every system: no separators, no characters Windows
    /// refuses, no leading dots, no control characters.
    pub fn safe_file_name(s: &str, fallback: &str) -> String {
        let mapped: String = s
            .chars()
            .map(|c| if matches!(c, '/' | ':' | '\\' | '<' | '>' | '"' | '|' | '?' | '*') || c.is_control() { '-' } else { c })
            .collect();
        let out = mapped.trim_start_matches('.').trim_matches(|c: char| c == ' ' || c == '\t');
        if out.is_empty() {
            return fallback.to_string();
        }
        out.chars().take(120).collect()
    }

    /// "Main menu: the Start button!" -> "main-menu-the-start-button"
    pub fn slug(title: &str) -> String {
        Self::slug_max(title, 40)
    }

    pub fn slug_max(title: &str, max_length: usize) -> String {
        let mut out = String::new();
        let mut dash = false;
        for c in title.nfkd().filter(|c| !is_combining_mark(*c)) {
            if c.is_ascii_alphanumeric() {
                out.push(c.to_ascii_lowercase());
                dash = false;
            } else if !dash && !out.is_empty() {
                out.push('-');
                dash = true;
            }
        }
        while out.ends_with('-') {
            out.pop();
        }
        if out.len() > max_length {
            out.truncate(max_length);
            while out.ends_with('-') {
                out.pop();
            }
        }
        out
    }

    /// "01-main-menu". The number is the item's id; the words follow its title.
    pub fn item_folder(id: i64, title: &str) -> String {
        let s = Self::slug(title);
        let n = format!("{id:02}");
        if s.is_empty() {
            n
        } else {
            format!("{n}-{s}")
        }
    }

    /// The first free "prefix-001.ext", "prefix-002.ext", … among `existing` names. A
    /// companion ("shot-002.orig.png", "clip-001-frames") also takes its number.
    pub fn next_media_name(prefix: &str, ext: &str, existing: &HashSet<String>) -> String {
        let lower: HashSet<String> = existing.iter().map(|s| s.to_lowercase()).collect();
        let mut n = 1;
        loop {
            let name = format!("{prefix}-{n:03}.{ext}");
            let stem = format!("{prefix}-{n:03}").to_lowercase();
            let taken = lower.iter().any(|e| *e == name.to_lowercase() || e.starts_with(&format!("{stem}.")) || e.starts_with(&format!("{stem}-")));
            if !taken {
                return name;
            }
            n += 1;
        }
    }

    /// The number an item folder starts with ("07-by-hand" -> 7); needs at least two digits.
    pub fn folder_number(name: &str) -> Option<i64> {
        let digits: String = name.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.len() < 2 {
            return None;
        }
        digits.parse().ok().filter(|n| *n > 0)
    }
}
