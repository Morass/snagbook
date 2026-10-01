//! Recording a rectangle of the screen: frames go into ffmpeg as they are taken, and beside
//! the video go the same companions the macOS app writes, for readers who cannot play a
//! video: `clip-NNN-frames/` (one still a second), `clip-NNN-contact.jpg` (a timestamped
//! grid) and `clip-NNN.json` (what was recorded and when).

use image::{codecs::jpeg::JpegEncoder, imageops, Rgba, RgbaImage};
use serde::Serialize;
use snagbook_core::{capture_math, FolderIdentity};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------- ffmpeg

/// ffmpeg from SNAGBOOK_FFMPEG, beside the app, or on the PATH.
pub fn find_ffmpeg() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("SNAGBOOK_FFMPEG") {
        return (!p.is_empty() && Path::new(&p).is_file()).then(|| PathBuf::from(p));
    }
    let exe = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        if dir.join(exe).is_file() {
            return Some(dir.join(exe));
        }
    }
    std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|d| d.join(exe)).find(|p| p.is_file()))
}

/// `ffmpeg -encoders`, given at most `limit`: a hanging ffmpeg is killed, not waited on.
pub fn encoder_list(ff: &Path, limit: Duration) -> Result<String, String> {
    let mut cmd = Command::new(ff);
    cmd.args(["-hide_banner", "-encoders"]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let mut child = cmd.spawn().map_err(|e| format!("ffmpeg could not start: {e}"))?;
    let mut out = child.stdout.take().ok_or("no output from ffmpeg")?;
    // Read on a thread: a long list would otherwise fill the pipe while we wait.
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        use std::io::Read;
        let _ = out.read_to_string(&mut s);
        s
    });
    let deadline = Instant::now() + limit;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("ffmpeg did not answer, so the video was not saved".into());
            }
        }
    }
    Ok(reader.join().unwrap_or_default())
}

/// How to encode: the extension and ffmpeg's output arguments, best first. H.264 in MP4 plays
/// everywhere Snagbook runs, including the macOS app; VP9 in WebM is the free fallback.
pub fn pick_codec(encoders: &str, bitrate: i64) -> Option<(&'static str, Vec<String>)> {
    let has = |name: &str| encoders.lines().any(|l| l.split_whitespace().nth(1) == Some(name));
    let b = format!("{bitrate}");
    let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    if has("libx264") {
        Some(("mp4", v(&["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-b:v", &b, "-movflags", "+faststart"])))
    } else if has("libopenh264") {
        Some(("mp4", v(&["-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-b:v", &b, "-movflags", "+faststart"])))
    } else if has("libvpx-vp9") {
        Some(("webm", v(&["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-row-mt", "1", "-pix_fmt", "yuv420p", "-b:v", &b])))
    } else if has("libvpx") {
        Some(("webm", v(&["-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-pix_fmt", "yuv420p", "-b:v", &b])))
    } else {
        None
    }
}

/// Average bit rate: about 0.1 bit per pixel per frame, between 0.6 and 6 Mbit/s.
pub fn bit_rate(w: u32, h: u32, fps: i64) -> i64 {
    ((w as f64 * h as f64 * fps.max(1) as f64 * 0.1) as i64).clamp(600_000, 6_000_000)
}

pub struct Encoder {
    /// Shared so a stuck ffmpeg can be killed from outside the thread that feeds it.
    child: Arc<std::sync::Mutex<Child>>,
    stdin: Option<ChildStdin>,
    stderr: Option<std::process::ChildStderr>,
}

impl Encoder {
    /// ffmpeg reading raw RGBA frames of `src` size and writing `out` at `dst` size.
    pub fn start(ffmpeg: &Path, args: &[String], src: (u32, u32), dst: (u32, u32), fps: i64, out: &Path) -> Result<Encoder, String> {
        let mut cmd = Command::new(ffmpeg);
        cmd.args(["-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba"])
            .args(["-s", &format!("{}x{}", src.0, src.1), "-framerate", &fps.to_string(), "-i", "-"])
            .args(["-vf", &format!("scale={}:{}:flags=bicubic", dst.0, dst.1), "-r", &fps.to_string()])
            .args(args)
            .arg(out)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // no console window
        }
        let mut child = cmd.spawn().map_err(|e| format!("ffmpeg could not start: {e}"))?;
        let stdin = child.stdin.take();
        let stderr = child.stderr.take();
        Ok(Encoder { child: Arc::new(std::sync::Mutex::new(child)), stdin, stderr })
    }

    pub fn killer(&self) -> Arc<std::sync::Mutex<Child>> {
        self.child.clone()
    }

    pub fn frame(&mut self, rgba: &[u8]) -> Result<(), String> {
        self.stdin.as_mut().ok_or("ffmpeg has stopped")?.write_all(rgba).map_err(|e| format!("ffmpeg stopped taking frames: {e}"))
    }

    /// Close ffmpeg's input and wait for it, at most `limit`; a stuck one is killed.
    pub fn finish(mut self, limit: Duration) -> Result<(), String> {
        drop(self.stdin.take());
        let deadline = Instant::now() + limit;
        let status = loop {
            let polled = self.child.lock().unwrap().try_wait();
            match polled {
                Ok(Some(st)) => break st,
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
                _ => {
                    // Killed and reaped: a process left over would hold the file open (so a
                    // failed video could not be removed on Windows) and linger as a zombie.
                    let mut child = self.child.lock().unwrap();
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("ffmpeg did not finish, so the video was not saved".into());
                }
            }
        };
        if status.success() {
            return Ok(());
        }
        let mut err = String::new();
        if let Some(mut e) = self.stderr.take() {
            use std::io::Read;
            let _ = e.read_to_string(&mut err);
        }
        Err(format!("ffmpeg failed: {}", err.lines().last().unwrap_or("")))
    }
}

/// Why recording cannot work in this desktop session, if it cannot. On Wayland every
/// screen read goes through the desktop's permission prompt, which a video cannot do.
pub fn unsupported_here(session_type: Option<&str>, wayland_display: Option<&str>) -> Option<&'static str> {
    let wayland = session_type.is_some_and(|t| t.eq_ignore_ascii_case("wayland")) || wayland_display.is_some_and(|d| !d.is_empty());
    wayland.then_some("Recording is not available on Wayland yet. Log in with an X11 (Xorg) session to record; screenshots work either way.")
}

// ---------------------------------------------------------------- pictures

pub fn jpeg(img: &RgbaImage, quality: u8) -> Result<Vec<u8>, String> {
    let rgb = image::DynamicImage::ImageRgba8(img.clone()).to_rgb8();
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality).encode_image(&rgb).map_err(|e| e.to_string())?;
    Ok(out)
}

/// `img` scaled down so its long side is at most `max` (never up).
pub fn fit(img: &RgbaImage, max: u32) -> RgbaImage {
    let (w, h) = img.dimensions();
    if w.max(h) <= max {
        return img.clone();
    }
    let k = max as f64 / w.max(h) as f64;
    imageops::resize(img, ((w as f64 * k).round() as u32).max(1), ((h as f64 * k).round() as u32).max(1), imageops::FilterType::Triangle)
}

/// A 3×5 pixel font for the digits, ':' and '.', enough for a timestamp.
fn glyph(c: char) -> [u8; 5] {
    match c {
        '0' => [0b111, 0b101, 0b101, 0b101, 0b111],
        '1' => [0b010, 0b110, 0b010, 0b010, 0b111],
        '2' => [0b111, 0b001, 0b111, 0b100, 0b111],
        '3' => [0b111, 0b001, 0b111, 0b001, 0b111],
        '4' => [0b101, 0b101, 0b111, 0b001, 0b001],
        '5' => [0b111, 0b100, 0b111, 0b001, 0b111],
        '6' => [0b111, 0b100, 0b111, 0b101, 0b111],
        '7' => [0b111, 0b001, 0b010, 0b010, 0b010],
        '8' => [0b111, 0b101, 0b111, 0b101, 0b111],
        '9' => [0b111, 0b101, 0b111, 0b001, 0b111],
        ':' => [0b000, 0b010, 0b000, 0b010, 0b000],
        '.' => [0b000, 0b000, 0b000, 0b000, 0b010],
        _ => [0; 5],
    }
}

/// Write `text` at (x, y) in white on a dark badge, each font pixel `k` pixels big.
pub fn label(img: &mut RgbaImage, x: u32, y: u32, text: &str, k: u32) {
    let (bw, bh) = (text.chars().count() as u32 * 4 * k + 2 * k, 7 * k);
    for yy in y..(y + bh).min(img.height()) {
        for xx in x..(x + bw).min(img.width()) {
            let p = img.get_pixel_mut(xx, yy);
            *p = Rgba([p[0] / 3, p[1] / 3, p[2] / 3, 255]);
        }
    }
    for (i, c) in text.chars().enumerate() {
        let rows = glyph(c);
        for (r, bits) in rows.iter().enumerate() {
            for col in 0..3u32 {
                if bits & (0b100 >> col) != 0 {
                    for dy in 0..k {
                        for dx in 0..k {
                            let (px, py) = (x + k + i as u32 * 4 * k + col * k + dx, y + k + r as u32 * k + dy);
                            if px < img.width() && py < img.height() {
                                img.put_pixel(px, py, Rgba([255, 255, 255, 255]));
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Tiles in a grid on a dark background, each with its time in the corner.
pub fn contact_sheet(tiles: &[(RgbaImage, f64)]) -> Option<RgbaImage> {
    let (tw, th) = tiles.first()?.0.dimensions();
    let (cols, rows) = capture_math::grid(tiles.len());
    let gap = 6u32;
    let (w, h) = (cols as u32 * tw + (cols as u32 + 1) * gap, rows as u32 * th + (rows as u32 + 1) * gap);
    let mut sheet = RgbaImage::from_pixel(w, h, Rgba([26, 26, 28, 255]));
    let k = (th / 60).max(2);
    for (i, (img, t)) in tiles.iter().enumerate() {
        let (c, r) = ((i % cols) as u32, (i / cols) as u32);
        let (x, y) = (gap + c * (tw + gap), gap + r * (th + gap));
        imageops::replace(&mut sheet, img, x as i64, y as i64);
        label(&mut sheet, x + 4, y + th.saturating_sub(7 * k + 4), &capture_math::stamp(*t), k);
    }
    Some(sheet)
}

/// The index in `have` (sorted times) nearest to `t`.
pub fn nearest(have: &[f64], t: f64) -> Option<usize> {
    have.iter().enumerate().min_by(|a, b| (a.1 - t).abs().total_cmp(&(b.1 - t).abs())).map(|(i, _)| i)
}

// ---------------------------------------------------------------- the recording

/// Stop, and when it was pressed: the recording ends at that moment, not when a slow screen
/// grab gets round to noticing it.
#[derive(Default)]
pub struct Stop {
    flag: AtomicBool,
    at: std::sync::Mutex<Option<Instant>>,
}

impl Stop {
    pub fn new() -> Arc<Stop> {
        Arc::new(Stop::default())
    }

    pub fn request(&self) {
        self.at.lock().unwrap().get_or_insert_with(Instant::now);
        self.flag.store(true, Ordering::SeqCst);
    }

    pub fn requested(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    fn at(&self) -> Option<Instant> {
        *self.at.lock().unwrap()
    }
}

#[derive(Serialize)]
pub struct Still {
    pub time: f64,
    pub file: String,
}

/// clip-NNN.json: the same fields as the macOS app's.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub video: Option<String>,
    pub duration: f64,
    pub width: u32,
    pub height: u32,
    pub fps: i64,
    pub recorded: String,
    pub stills: Vec<Still>,
    pub contact_sheet: Option<String>,
    pub source: Option<String>,
    pub app: Option<String>,
}

pub struct Plan {
    /// The item's media folder and the clip's stem ("clip-001").
    pub dir: PathBuf,
    pub stem: String,
    pub fps: i64,
    pub max_long_edge: i64,
    pub max_stills: i64,
    pub ffmpeg: Option<PathBuf>,
    pub source: String,
    pub destination: Option<(PathBuf, FolderIdentity)>,
    /// How long ffmpeg may take to finish after Stop before it is given up on.
    pub finish_timeout: Duration,
}

fn destination_current(destination: &Option<(PathBuf, FolderIdentity)>) -> bool {
    destination.as_ref().is_none_or(|(path, identity)| identity.matches_path(path))
}

fn require_destination(destination: &Option<(PathBuf, FolderIdentity)>) -> Result<(), String> {
    destination_current(destination).then_some(()).ok_or_else(|| "the recording's item folder is gone or was replaced".into())
}

pub struct Finished {
    /// "clip-001.mp4", or None when there was no ffmpeg to make a video.
    pub video: Option<String>,
    pub sheet: Option<String>,
    pub duration: f64,
    pub problem: Option<String>,
}

/// The most thumbnails kept at once for the contact sheet (about half a megabyte each).
const MAX_THUMBS: usize = 64;

/// Keep every other thumbnail, the first always.
fn thin(thumbs: &mut Vec<(f64, RgbaImage)>) {
    let mut i = 0;
    thumbs.retain(|_| {
        i += 1;
        i % 2 == 1
    });
}

/// Take frames from `grab` until `stop` is set; write the video and its companions. A failed
/// recording leaves nothing behind: not the empty file holding its name, not its frames.
pub fn run(grab: impl FnMut() -> Result<RgbaImage, String>, plan: Plan, stop: Arc<Stop>) -> Result<Finished, String> {
    let (dir, stem) = (plan.dir.clone(), plan.stem.clone());
    let destination = plan.destination.clone();
    let result = record(grab, plan, stop);
    if result.is_err() && destination_current(&destination) {
        let placeholder = dir.join(format!("{stem}.mp4"));
        if std::fs::metadata(&placeholder).map(|m| m.len() == 0).unwrap_or(false) {
            let _ = std::fs::remove_file(&placeholder);
        }
        let _ = std::fs::remove_dir_all(dir.join(format!("{stem}-frames")));
    }
    result
}

fn record(mut grab: impl FnMut() -> Result<RgbaImage, String>, plan: Plan, stop: Arc<Stop>) -> Result<Finished, String> {
    require_destination(&plan.destination)?;
    let first = grab()?;
    let src = first.dimensions();
    let dst = capture_math::output_size(src.0 as f64, src.1 as f64, plan.max_long_edge);
    let fps = plan.fps.clamp(1, 60);
    let mut problem = None;
    // Everything about ffmpeg happens on a thread of its own: asking it for its encoders,
    // starting it, feeding it. The first run of a freshly downloaded ffmpeg can take seconds
    // (a virus scan), and none of that may hold up the screen being read or the clock. A frame
    // travels with how many times it is to be shown, so a backlog costs no memory.
    // A few frames of slack only: each is a whole picture (8 MB at 1080p), and a longer backlog
    // is merged into the latest frame anyway.
    let (tx, rx) = std::sync::mpsc::sync_channel::<(Arc<RgbaImage>, u64)>(8);
    let killer: Arc<std::sync::Mutex<Option<Arc<std::sync::Mutex<Child>>>>> = Arc::new(std::sync::Mutex::new(None));
    let writer = match plan.ffmpeg.clone() {
        None => {
            problem = Some("ffmpeg was not found, so only the stills and the contact sheet were saved".into());
            None
        }
        Some(ff) => {
            let (dir, stem) = (plan.dir.clone(), plan.stem.clone());
            let destination = plan.destination.clone();
            let slot = killer.clone();
            let limit = plan.finish_timeout;
            let (done_tx, done_rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let r = (|| -> Result<String, String> {
                let encoders = encoder_list(&ff, Duration::from_secs(20))?;
                let (ext, args) = pick_codec(&encoders, bit_rate(dst.0, dst.1, fps)).ok_or("this ffmpeg has no H.264 or VP9 encoder")?;
                let name = format!("{stem}.{ext}");
                require_destination(&destination)?;
                let mut enc = Encoder::start(&ff, &args, src, dst, fps, &dir.join(&name))?;
                *slot.lock().unwrap() = Some(enc.killer());
                let mut failed = None;
                for (frame, times) in rx {
                    for _ in 0..times {
                        if failed.is_none() {
                            if let Err(e) = require_destination(&destination).and_then(|_| enc.frame(frame.as_raw())) {
                                failed = Some(e);
                            }
                        }
                    }
                }
                let done = enc.finish(limit);
                let r = match failed {
                    Some(e) => Err(e),
                    None => done.map(|_| name.clone()),
                };
                // A video that did not finish is not a video: nothing would play it.
                if r.is_err() {
                    if destination_current(&destination) { let _ = std::fs::remove_file(dir.join(&name)); }
                }
                r
                })();
                let _ = done_tx.send(r);
            });
            Some(done_rx)
        }
    };
    let frames_dir = plan.dir.join(format!("{}-frames", plan.stem));
    require_destination(&plan.destination)?;
    let _ = std::fs::remove_dir_all(&frames_dir);
    std::fs::create_dir_all(&frames_dir).map_err(|e| e.to_string())?;
    let mut stills: Vec<(f64, PathBuf)> = vec![];
    let mut thumbs: Vec<(f64, RgbaImage)> = vec![];
    // Every half second at first; a long recording keeps fewer, further apart, so their
    // memory stays bounded (the contact sheet needs 16).
    let mut thumb_every = 0.5;
    let start = Instant::now();
    let mut written: u64 = 0;
    let mut frame = Arc::new(first);
    let mut last_good = frame.clone();
    // Frames not yet taken by the writer. Never block on it: a backlog becomes the latest
    // frame shown for longer, and the loop keeps reading the screen and watching for Stop.
    let mut pending: Option<(Arc<RgbaImage>, u64)> = None;
    let offer = |pending: &mut Option<(Arc<RgbaImage>, u64)>, frame: &Arc<RgbaImage>, add: u64| {
        if add > 0 {
            let n = pending.take().map_or(0, |p| p.1);
            *pending = Some((frame.clone(), n + add));
        }
        if let Some(p) = pending.take() {
            if let Err(std::sync::mpsc::TrySendError::Full(p)) = tx.try_send(p) {
                *pending = Some(p);
            }
        }
    };
    loop {
        require_destination(&plan.destination)?;
        let t = start.elapsed().as_secs_f64();
        if frame.dimensions() == src {
            // The video keeps the wall clock: a slow grab repeats the frame instead of
            // speeding time up.
            let due = (t * fps as f64) as u64 + 1;
            if writer.is_some() {
                offer(&mut pending, &frame, due.saturating_sub(written));
            }
            written = written.max(due);
            last_good = frame.clone();
            if stills.last().map_or(true, |(s, _)| t - s >= 1.0 - 0.5 / fps as f64) {
                let p = frames_dir.join(format!("t{:06}.jpg", stills.len()));
                std::fs::write(&p, jpeg(&fit(&frame, 1568), 72)?).map_err(|e| e.to_string())?;
                stills.push((t, p));
            }
            if thumbs.last().map_or(true, |(s, _)| t - s >= thumb_every - 0.5 / fps as f64) {
                thumbs.push((t, fit(&frame, 480)));
                if thumbs.len() >= MAX_THUMBS {
                    thin(&mut thumbs);
                    thumb_every *= 2.0;
                }
            }
        }
        if stop.requested() {
            break;
        }
        let next = Duration::from_secs_f64(written as f64 / fps as f64);
        if let Some(wait) = next.checked_sub(start.elapsed()) {
            std::thread::sleep(wait);
        }
        if stop.requested() {
            break;
        }
        match grab() {
            // A grab that came back after Stop shows the screen after it: not part of the clip.
            Ok(_) if stop.requested() => break,
            Ok(f) => frame = Arc::new(f),
            // The screen went away (locked, unplugged): what was recorded so far is kept.
            Err(e) => {
                problem = Some(format!("the recording ended early: {e}"));
                break;
            }
        }
    }
    // Up to the moment Stop was pressed, whatever the last grab cost.
    let end = stop.at().map_or_else(|| start.elapsed(), |at| at.saturating_duration_since(start));
    let due = (end.as_secs_f64() * fps as f64) as u64;
    if writer.is_some() {
        offer(&mut pending, &last_good, due.saturating_sub(written));
        let deadline = Instant::now() + plan.finish_timeout;
        while pending.is_some() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            offer(&mut pending, &last_good, 0);
        }
    }
    written = written.max(due);
    // Frames counted after Stop (a grab that returned late) do not lengthen the clip.
    let written = written.min(due.max(1));
    let duration = written as f64 / fps as f64;
    drop(tx);
    let mut video_name = None;
    if let Some(done) = writer {
        let result = done.recv_timeout(plan.finish_timeout + Duration::from_secs(2)).unwrap_or_else(|_| {
            // Stuck writing to an ffmpeg that stopped reading: kill it, which ends the write.
            if let Some(child) = killer.lock().unwrap().as_ref() {
                let _ = child.lock().unwrap().kill();
            }
            done.recv_timeout(Duration::from_secs(5)).unwrap_or_else(|_| Err("ffmpeg did not finish, so the video was not saved".into()))
        });
        match result {
            Ok(name) => video_name = Some(name),
            Err(e) => problem = Some(match problem { Some(p) => format!("{p}; {e}"), None => e }),
        }
    }

    // The stills that are kept: the macOS app's times, each from the nearest second taken.
    require_destination(&plan.destination)?;
    let have: Vec<f64> = stills.iter().map(|s| s.0).collect();
    let mut kept = vec![];
    for (i, want) in capture_math::still_times(duration, plan.max_stills).into_iter().enumerate() {
        require_destination(&plan.destination)?;
        let Some(j) = nearest(&have, want) else { continue };
        let name = format!("{:04}.jpg", i + 1);
        std::fs::copy(&stills[j].1, frames_dir.join(&name)).map_err(|e| e.to_string())?;
        kept.push(Still { time: (have[j] * 10.0).round() / 10.0, file: format!("{}-frames/{name}", plan.stem) });
    }
    for (_, p) in &stills {
        if destination_current(&plan.destination) { let _ = std::fs::remove_file(p); }
    }

    // The app reserves "<stem>.mp4" with an empty file while recording; drop it unless it is
    // the video.
    let placeholder = plan.dir.join(format!("{}.mp4", plan.stem));
    require_destination(&plan.destination)?;
    if video_name.as_deref() != Some(&format!("{}.mp4", plan.stem)) && std::fs::metadata(&placeholder).map(|m| m.len() == 0).unwrap_or(false) {
        let _ = std::fs::remove_file(&placeholder);
    }

    let thumb_times: Vec<f64> = thumbs.iter().map(|t| t.0).collect();
    let tiles: Vec<(RgbaImage, f64)> = capture_math::sheet_times(duration, 16)
        .into_iter()
        .filter_map(|t| nearest(&thumb_times, t).map(|j| (thumbs[j].1.clone(), thumbs[j].0)))
        .collect();
    let sheet_name = format!("{}-contact.jpg", plan.stem);
    let sheet = match contact_sheet(&tiles) {
        Some(img) => {
            require_destination(&plan.destination)?;
            std::fs::write(plan.dir.join(&sheet_name), jpeg(&img, 75)?).map_err(|e| e.to_string())?;
            Some(sheet_name)
        }
        None => None,
    };

    let info = Info {
        video: video_name.clone(),
        duration: (duration * 100.0).round() / 100.0,
        width: dst.0,
        height: dst.1,
        fps,
        recorded: chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        stills: kept,
        contact_sheet: sheet.clone(),
        source: Some(plan.source.clone()),
        app: Some("Snagbook".into()),
    };
    let json = serde_json::to_string_pretty(&info).map_err(|e| e.to_string())?;
    require_destination(&plan.destination)?;
    std::fs::write(plan.dir.join(format!("{}.json", plan.stem)), json).map_err(|e| e.to_string())?;
    Ok(Finished { video: video_name, sheet, duration, problem })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codec_choice_prefers_h264() {
        let list = " V....D libvpx-vp9  VP9\n V....D libx264  H.264\n";
        assert_eq!(pick_codec(list, 1_000_000).unwrap().0, "mp4");
        assert_eq!(pick_codec(" V....D libvpx-vp9  VP9\n", 1).unwrap().0, "webm");
        assert!(pick_codec(" V....D mpeg4  MPEG-4 part 2\n", 1).is_none(), "a codec browsers cannot play is not used");
        assert!(pick_codec(" V....D libx264rgb  RGB\n", 1).is_none(), "a longer name is not the encoder");
    }

    #[test]
    fn recording_says_no_on_wayland() {
        assert!(unsupported_here(Some("wayland"), None).is_some());
        assert!(unsupported_here(Some("x11"), Some("wayland-0")).is_some(), "an X11 app inside a Wayland desktop still cannot read the screen freely");
        assert!(unsupported_here(Some("x11"), None).is_none());
        assert!(unsupported_here(None, None).is_none(), "Windows has neither");
    }

    #[test]
    fn bit_rates_have_a_floor_and_a_ceiling() {
        assert_eq!(bit_rate(100, 100, 15), 600_000);
        assert_eq!(bit_rate(3840, 2160, 60), 6_000_000);
        assert_eq!(bit_rate(1280, 720, 15), 1_382_400);
    }

    #[test]
    fn nearest_time() {
        assert_eq!(nearest(&[0.0, 1.02, 2.01], 1.9), Some(2));
        assert_eq!(nearest(&[], 1.0), None);
    }

    #[test]
    fn the_contact_sheet_is_a_grid_with_labels() {
        let tiles: Vec<(RgbaImage, f64)> = (0..5).map(|i| (RgbaImage::from_pixel(40, 30, Rgba([0, 90, 200, 255])), i as f64)).collect();
        let sheet = contact_sheet(&tiles).unwrap();
        assert_eq!(sheet.dimensions(), (3 * 40 + 4 * 6, 2 * 30 + 3 * 6));
        let white = sheet.pixels().filter(|p| p.0 == [255, 255, 255, 255]).count();
        assert!(white > 20, "the time stamps are drawn: {white} white pixels");
    }

    fn with_ffmpeg() -> Option<PathBuf> {
        find_ffmpeg()
    }

    /// A 2.4 s synthetic recording: the files the macOS app would write, with real ffmpeg when
    /// there is one on this machine.
    #[test]
    fn a_recording_writes_the_video_and_its_companions() {
        let dir = tempfile::tempdir().unwrap();
        let mut n = 0u8;
        let grab = move || {
            n = n.wrapping_add(9);
            Ok(RgbaImage::from_pixel(321, 241, Rgba([n, 128, 255 - n, 255])))
        };
        let stop = Stop::new();
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(2400));
            s2.request();
        });
        let ff = with_ffmpeg();
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: ff.clone(), source: "test".into(), destination: None, finish_timeout: Duration::from_secs(60) };
        let f = run(grab, plan, stop).unwrap();
        assert!((2.3..3.2).contains(&f.duration), "{}", f.duration);
        let info: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(dir.path().join("clip-001.json")).unwrap()).unwrap();
        assert_eq!(info["width"], 320, "even width");
        assert_eq!(info["height"], 240);
        assert_eq!(info["stills"].as_array().unwrap().len(), 3, "0, 1 and 2 s");
        assert_eq!(info["stills"][0]["file"], "clip-001-frames/0001.jpg");
        assert!(dir.path().join("clip-001-frames/0003.jpg").is_file());
        assert!(!dir.path().join("clip-001-frames/t000000.jpg").exists(), "working files are removed");
        assert!(dir.path().join("clip-001-contact.jpg").is_file());
        match ff {
            Some(_) => {
                assert_eq!(f.video.as_deref(), Some("clip-001.mp4"), "{:?}", f.problem);
                assert!(std::fs::metadata(dir.path().join("clip-001.mp4")).unwrap().len() > 1000);
            }
            None => assert!(f.video.is_none() && f.problem.is_some()),
        }
    }

    /// A stand-in ffmpeg that takes longer to start reading than the whole recording lasts (like a first run on
    /// Windows, scanned by the virus checker) must not shorten the recording.
    #[cfg(unix)]
    #[test]
    fn a_slow_encoder_does_not_stop_the_clock() {
        let Some(real) = find_ffmpeg() else { return };
        let dir = tempfile::tempdir().unwrap();
        let slow = dir.path().join("slow-ffmpeg");
        std::fs::write(&slow, format!("#!/bin/sh\ncase \"$*\" in *-encoders*) exec '{0}' \"$@\";; esac\nsleep 4\nexec '{0}' \"$@\"\n", real.display())).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).unwrap();
        let stop = Stop::new();
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(3000));
            s2.request();
        });
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: Some(slow), source: "test".into(), destination: None, finish_timeout: Duration::from_secs(60) };
        // Big frames fill the pipe at once, so a blocking write would stall the grab loop.
        let f = run(|| Ok(RgbaImage::from_pixel(1280, 720, Rgba([200, 30, 30, 255]))), plan, stop).unwrap();
        assert_eq!(f.video.as_deref(), Some("clip-001.mp4"), "{:?}", f.problem);
        assert!(f.duration >= 2.8, "the clip is {}s long, not 3", f.duration);
        let info: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(dir.path().join("clip-001.json")).unwrap()).unwrap();
        assert!(info["stills"].as_array().unwrap().len() >= 3, "stills kept coming while ffmpeg was slow");
    }

    /// A stand-in ffmpeg whose encoder list takes longer than the whole recording (a first
    /// run on Windows, scanned by the virus checker) must not shorten the recording either.
    #[cfg(unix)]
    #[test]
    fn a_slow_first_answer_from_ffmpeg_does_not_stop_the_clock() {
        let Some(real) = find_ffmpeg() else { return };
        let dir = tempfile::tempdir().unwrap();
        let slow = dir.path().join("slow-ffmpeg");
        std::fs::write(&slow, format!("#!/bin/sh\ncase \"$*\" in *-encoders*) sleep 4;; esac\nexec '{0}' \"$@\"\n", real.display())).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).unwrap();
        let stop = Stop::new();
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(3000));
            s2.request();
        });
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: Some(slow), source: "test".into(), destination: None, finish_timeout: Duration::from_secs(60) };
        let f = run(|| Ok(RgbaImage::from_pixel(320, 240, Rgba([30, 30, 200, 255]))), plan, stop).unwrap();
        assert!(f.duration >= 2.8, "the clip is {}s long, not 3", f.duration);
        assert_eq!(f.video.as_deref(), Some("clip-001.mp4"), "{:?}", f.problem);
    }

    /// An ffmpeg that never reads its input must not hang Stop: it is killed after the
    /// deadline, the stills are kept, and the reason is given.
    #[cfg(unix)]
    #[test]
    fn a_stuck_ffmpeg_does_not_hang_stop() {
        let Some(real) = find_ffmpeg() else { return };
        let dir = tempfile::tempdir().unwrap();
        let stuck = dir.path().join("stuck-ffmpeg");
        std::fs::write(&stuck, format!("#!/bin/sh\ncase \"$*\" in *-encoders*) exec '{0}' \"$@\";; esac\nexec sleep 600\n", real.display())).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stuck, std::fs::Permissions::from_mode(0o755)).unwrap();
        let stop = Stop::new();
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(12000));
            s2.request();
        });
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: Some(stuck), source: "test".into(), destination: None, finish_timeout: Duration::from_secs(2) };
        let t0 = Instant::now();
        // Big frames: the pipe and then the queue fill within the 12 seconds.
        let f = run(|| Ok(RgbaImage::from_pixel(1280, 720, Rgba([9, 9, 9, 255]))), plan, stop).unwrap();
        assert!(t0.elapsed() < Duration::from_secs(25), "Stop took {:?}", t0.elapsed());
        assert!(f.video.is_none() && f.problem.as_deref().unwrap_or("").contains("ffmpeg"), "{:?}", f.problem);
        assert!(f.duration >= 11.5, "{}", f.duration);
        assert!(dir.path().join("clip-001-frames/0012.jpg").is_file(), "the stills are kept");
    }

    /// A grab that takes seconds (a busy machine) must not stretch the clip past Stop.
    #[test]
    fn the_clip_ends_when_stop_is_pressed() {
        let dir = tempfile::tempdir().unwrap();
        let stop = Stop::new();
        let s2 = stop.clone();
        let (slow_tx, slow_rx) = std::sync::mpsc::sync_channel(0);
        std::thread::spawn(move || {
            slow_rx.recv().unwrap();
            std::thread::sleep(Duration::from_millis(300));
            s2.request();
        });
        let mut n = 0;
        let grab = move || {
            n += 1;
            if n == 2 {
                slow_tx.send(()).unwrap();
                std::thread::sleep(Duration::from_millis(3000)); // the grab after Stop is slow
            }
            Ok(RgbaImage::from_pixel(64, 48, Rgba([1, 2, 3, 255])))
        };
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: None, source: "test".into(), destination: None, finish_timeout: Duration::from_secs(60) };
        let f = run(grab, plan, stop).unwrap();
        assert!(f.duration < 1.0, "the clip runs {}s past a Stop during a slow grab", f.duration);
    }

    #[cfg(unix)]
    #[test]
    fn a_hanging_encoder_list_is_given_up_on() {
        let dir = tempfile::tempdir().unwrap();
        let hang = dir.path().join("hang");
        std::fs::write(&hang, "#!/bin/sh\nexec sleep 600\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hang, std::fs::Permissions::from_mode(0o755)).unwrap();
        let t0 = Instant::now();
        assert!(encoder_list(&hang, Duration::from_millis(500)).is_err());
        assert!(t0.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn an_unused_reservation_is_removed() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("clip-004.mp4"), b"").unwrap();
        let stop = Stop::new();
        stop.request();
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-004".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: None, source: "test".into(), destination: None, finish_timeout: Duration::from_secs(60) };
        run(|| Ok(RgbaImage::from_pixel(10, 10, Rgba([1, 2, 3, 255]))), plan, stop).unwrap();
        assert!(!dir.path().join("clip-004.mp4").exists(), "no ffmpeg: the empty reservation goes");
    }

    #[test]
    fn without_ffmpeg_the_stills_still_come() {
        let dir = tempfile::tempdir().unwrap();
        let stop = Stop::new();
        stop.request();
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-002".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: None, source: "test".into(), destination: None, finish_timeout: Duration::from_secs(60) };
        let f = run(|| Ok(RgbaImage::from_pixel(10, 10, Rgba([1, 2, 3, 255]))), plan, stop).unwrap();
        assert!(f.video.is_none());
        assert!(f.problem.unwrap().contains("ffmpeg"));
        assert!(dir.path().join("clip-002-frames/0001.jpg").is_file());
    }

    #[test]
    fn a_replacement_item_stops_recording_without_cleaning_its_files() {
        let root = tempfile::tempdir().unwrap();
        let mut session = snagbook_core::Session::create_now(&root.path().to_string_lossy(), &snagbook_core::Config::default()).unwrap();
        let id = session.add_item(None, chrono::Utc::now()).unwrap().id;
        let item_dir = session.item_dir(id).unwrap();
        let identity = session.item_identity(id).unwrap();
        let media = session.media_dir(id).unwrap();
        std::fs::create_dir(&media).unwrap();
        let stop = Stop::new();
        let request = stop.clone();
        let held = session.dir.join("held-recording-item");
        let replacement_frames = media.join("clip-001-frames");
        let mut grabs = 0;
        let plan = Plan { dir: media, stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: None, source: "test".into(), destination: Some((item_dir.clone(), identity)), finish_timeout: Duration::from_secs(60) };

        let result = run(|| {
            grabs += 1;
            if grabs == 2 {
                std::fs::rename(&item_dir, &held).unwrap();
                std::fs::create_dir_all(&replacement_frames).unwrap();
                std::fs::write(replacement_frames.join("keep.jpg"), b"replacement").unwrap();
                request.request();
            }
            Ok(RgbaImage::from_pixel(10, 10, Rgba([1, 2, 3, 255])))
        }, plan, stop);

        assert!(result.err().unwrap().contains("replaced"));
        assert_eq!(std::fs::read(replacement_frames.join("keep.jpg")).unwrap(), b"replacement");
    }

    fn plan(dir: &std::path::Path, ffmpeg: Option<PathBuf>) -> Plan {
        Plan { dir: dir.to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg, source: "test".into(), destination: None, finish_timeout: Duration::from_secs(20) }
    }

    /// The screen cannot be read at all: nothing is left behind, not even the file holding
    /// the name.
    #[test]
    fn a_recording_that_never_starts_leaves_nothing() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("clip-001.mp4"), b"").unwrap();
        let r = run(|| Err("no screen".to_string()), plan(dir.path(), None), Stop::new());
        assert!(r.is_err());
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0, "the folder is as it was before");
    }

    /// The screen goes away part way: the clip so far is kept, and the reason given.
    #[test]
    fn a_screen_lost_part_way_keeps_what_was_recorded() {
        let dir = tempfile::tempdir().unwrap();
        let t0 = Instant::now();
        let grab = move || if t0.elapsed() < Duration::from_millis(1500) { Ok(RgbaImage::from_pixel(64, 48, Rgba([9, 9, 9, 255]))) } else { Err("the screen was locked".to_string()) };
        let f = run(grab, plan(dir.path(), find_ffmpeg()), Stop::new()).unwrap();
        assert!(f.problem.as_deref().unwrap_or("").contains("the screen was locked"), "{:?}", f.problem);
        assert!((1.3..2.0).contains(&f.duration), "{}", f.duration);
        assert!(dir.path().join("clip-001.json").is_file() && dir.path().join("clip-001-contact.jpg").is_file());
    }

    /// An encoder that fails leaves no half-written video under the clip's name.
    #[cfg(unix)]
    #[test]
    fn a_failed_video_is_removed() {
        let Some(real) = find_ffmpeg() else { return };
        let dir = tempfile::tempdir().unwrap();
        let bad = dir.path().join("bad-ffmpeg");
        // Lists the real encoders, then writes a few bytes of "video" and fails.
        std::fs::write(&bad, format!("#!/bin/sh\ncase \"$*\" in *-encoders*) exec '{0}' \"$@\";; esac\nfor a; do out=$a; done\nprintf junk > \"$out\"\ncat > /dev/null\nexit 1\n", real.display())).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bad, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.path().join("clip-001.mp4"), b"").unwrap();
        let stop = Stop::new();
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1200));
            s2.request();
        });
        let f = run(|| Ok(RgbaImage::from_pixel(64, 48, Rgba([9, 9, 9, 255]))), plan(dir.path(), Some(bad)), stop).unwrap();
        assert!(f.video.is_none() && f.problem.is_some(), "{:?}", f.problem);
        assert!(!dir.path().join("clip-001.mp4").exists(), "no broken clip-001.mp4 is left");
        assert!(dir.path().join("clip-001-contact.jpg").is_file(), "the stills are still kept");
    }

    #[test]
    fn thumbnails_are_thinned_evenly() {
        let mut t: Vec<(f64, RgbaImage)> = (0..64).map(|i| (i as f64 * 0.5, RgbaImage::new(1, 1))).collect();
        thin(&mut t);
        assert_eq!(t.len(), 32);
        assert_eq!(t[0].0, 0.0);
        assert_eq!(t[1].0, 1.0);
        assert_eq!(t[31].0, 31.0);
    }

    /// A screen grab that comes back after Stop adds nothing to the video: the frames sent to
    /// ffmpeg match the clip's length.
    #[cfg(unix)]
    #[test]
    fn a_grab_returning_after_stop_does_not_lengthen_the_video() {
        let dir = tempfile::tempdir().unwrap();
        let counting = dir.path().join("counting-ffmpeg");
        // Claims H.264, then keeps the raw frames it is given as the "video".
        std::fs::write(&counting, "#!/bin/sh\ncase \"$*\" in *-encoders*) echo ' V....D libx264  H.264'; exit 0;; esac\nfor a; do out=$a; done\ncat > \"$out\"\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&counting, std::fs::Permissions::from_mode(0o755)).unwrap();
        let stop = Stop::new();
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1000));
            s2.request();
        });
        // Each grab takes 700 ms, so the one under way at Stop returns 400 ms after it.
        let grab = || {
            std::thread::sleep(Duration::from_millis(700));
            Ok(RgbaImage::from_pixel(64, 48, Rgba([9, 9, 9, 255])))
        };
        let f = run(grab, plan(dir.path(), Some(counting)), stop).unwrap();
        assert_eq!(f.video.as_deref(), Some("clip-001.mp4"), "{:?}", f.problem);
        let frames = std::fs::metadata(dir.path().join("clip-001.mp4")).unwrap().len() / (64 * 48 * 4);
        let expected = (f.duration * 15.0).round() as u64;
        assert!(frames <= expected + 1, "{frames} frames sent for a {}s clip ({expected} expected)", f.duration);
    }
}
