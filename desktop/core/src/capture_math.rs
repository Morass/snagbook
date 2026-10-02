//! Numbers for recording and for the stills written beside a video; the same rules as the
//! macOS app, so a recording made anywhere looks the same to whoever reads it.

/// Output size for a region of `w`×`h` pixels: never larger than `max_long_edge` on its long
/// side, never upscaled, and even in both directions (H.264 needs that).
pub fn output_size(w: f64, h: f64, max_long_edge: i64) -> (u32, u32) {
    if !(w > 0.0 && h > 0.0) {
        return (2, 2);
    }
    let long = w.max(h);
    let scale = if long > max_long_edge as f64 { max_long_edge as f64 / long } else { 1.0 };
    let even = |v: f64| (((v * scale).floor() as i64) & !1).max(2) as u32;
    (even(w), even(h))
}

/// Times (seconds) of the stills: one per second, evenly spread when that would be more than
/// `max`. Always includes a frame near the start and near the end.
pub fn still_times(duration: f64, max: i64) -> Vec<f64> {
    if !(duration > 0.0) || max <= 0 {
        return vec![];
    }
    let per_second = duration.floor() as i64 + 1;
    let n = per_second.min(max);
    if n == 1 {
        return vec![0.0];
    }
    let last = (duration - 0.05).max(0.0);
    if per_second <= max {
        let mut t: Vec<f64> = (0..n).map(|i| i as f64).collect();
        if let Some(l) = t.last_mut() {
            if *l > last {
                *l = last;
            }
        }
        return t;
    }
    (0..n).map(|i| last * i as f64 / (n - 1) as f64).collect()
}

/// Up to `count` times spread across the clip for the contact sheet.
pub fn sheet_times(duration: f64, count: i64) -> Vec<f64> {
    if !(duration > 0.0) || count <= 0 {
        return vec![];
    }
    let n = count.min((duration * 2.0) as i64 + 1).max(1);
    if n == 1 {
        return vec![0.0];
    }
    let last = (duration - 0.05).max(0.0);
    (0..n).map(|i| last * i as f64 / (n - 1) as f64).collect()
}

/// Columns and rows for `n` tiles: as square as possible, wider than tall.
pub fn grid(n: usize) -> (usize, usize) {
    if n == 0 {
        return (0, 0);
    }
    let cols = (n as f64).sqrt().ceil() as usize;
    (cols, n.div_ceil(cols))
}

/// "0:07.5", "1:02.0", "1:00:03.0"
pub fn stamp(t: f64) -> String {
    let tenths = (t * 10.0).round() as i64;
    let (s, f) = (tenths / 10, tenths % 10);
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{sec:02}.{f}")
    } else {
        format!("{m}:{sec:02}.{f}")
    }
}

/// "0:12", "1:05", for a caption.
pub fn duration(t: f64) -> String {
    let s = t.round() as i64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}
