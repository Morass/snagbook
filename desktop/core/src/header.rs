use chrono::{DateTime, Local, Utc};

/// Fills the placeholders of the session header: {session} the session folder, {readme}
/// its README.md, {date} the day it started, {items} how many items it has.
pub fn render_header(template: &str, session: &str, date: DateTime<Utc>, items: usize) -> String {
    let readme = if session.ends_with('/') { format!("{session}README.md") } else { format!("{session}/README.md") };
    template
        .replace("{session}", session)
        .replace("{readme}", &readme)
        .replace("{date}", &date.with_timezone(&Local).format("%Y-%m-%d").to_string())
        .replace("{items}", &items.to_string())
}
