use std::path::PathBuf;

/// "~" spelling of paths. The "~" form is the one that means the same thing on every
/// machine, so it is what sessions store and what the hand-off text shows.
pub struct Paths;

impl Paths {
    /// The home folder, from the environment first so tests and a redirected HOME are
    /// honoured.
    pub fn home() -> String {
        for key in ["HOME", "USERPROFILE"] {
            if let Ok(h) = std::env::var(key) {
                if !h.is_empty() {
                    return h;
                }
            }
        }
        String::from("/")
    }

    /// "~/x" -> "<home>/x". Symlinks are left alone on purpose: a shared folder may be a
    /// link whose target differs between machines.
    pub fn expand(path: &str) -> String {
        if path == "~" {
            return Self::home();
        }
        if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
            return format!("{}/{}", Self::home().trim_end_matches(['/', '\\']), rest);
        }
        path.to_string()
    }

    /// "<home>/x" -> "~/x"; anything outside the home folder is returned unchanged.
    pub fn abbreviate(path: &str) -> String {
        let home = Self::home();
        let h = home.trim_end_matches(['/', '\\']);
        if h.is_empty() {
            return path.to_string();
        }
        if path == h {
            return "~".into();
        }
        for sep in ['/', '\\'] {
            if let Some(rest) = path.strip_prefix(&format!("{h}{sep}")) {
                return format!("~/{}", rest.replace('\\', "/"));
            }
        }
        path.to_string()
    }

    pub fn path(path: &str) -> PathBuf {
        PathBuf::from(Self::expand(path))
    }
}
