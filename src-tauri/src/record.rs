//! Recording a rectangle of the screen: frames go into ffmpeg as they are taken, and beside
//! the video go the same companions the macOS app writes, for readers who cannot play a
//! video: `clip-NNN-frames/` (one still a second), `clip-NNN-contact.jpg` (a timestamped
//! grid) and `clip-NNN.json` (what was recorded and when).

use image::{codecs::jpeg::JpegEncoder, imageops, Rgba, RgbaImage};
use serde::Serialize;
use snagbook_core::capture_math;
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
                    let _ = self.child.lock().unwrap().kill();
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
    /// How long ffmpeg may take to finish after Stop before it is given up on.
    pub finish_timeout: Duration,
}

pub struct Finished {
    /// "clip-001.mp4", or None when there was no ffmpeg to make a video.
    pub video: Option<String>,
    pub sheet: Option<String>,
    pub duration: f64,
    pub problem: Option<String>,
}

/// Take frames from `grab` until `stop` is set; write the video and its companions.
pub fn run(mut grab: impl FnMut() -> Result<RgbaImage, String>, plan: Plan, stop: Arc<AtomicBool>) -> Result<Finished, String> {
    let first = grab()?;
    let src = first.dimensions();
    let dst = capture_math::output_size(src.0 as f64, src.1 as f64, plan.max_long_edge);
    let fps = plan.fps.clamp(1, 60);
    let mut problem = None;
    // Everything about ffmpeg happens on a thread of its own: asking it for its encoders,
    // starting it, feeding it. The first run of a freshly downloaded ffmpeg can take seconds
    // (a virus scan), and none of that may hold up the screen being read or the clock. A frame
    // travels with how many times it is to be shown, so a backlog costs no memory.
    let (tx, rx) = std::sync::mpsc::sync_channel::<(Arc<RgbaImage>, u64)>(fps as usize * 10);
    let killer: Arc<std::sync::Mutex<Option<Arc<std::sync::Mutex<Child>>>>> = Arc::new(std::sync::Mutex::new(None));
    let writer = match plan.ffmpeg.clone() {
        None => {
            problem = Some("ffmpeg was not found, so only the stills and the contact sheet were saved".into());
            None
        }
        Some(ff) => {
            let (dir, stem) = (plan.dir.clone(), plan.stem.clone());
            let slot = killer.clone();
            let limit = plan.finish_timeout;
            let (done_tx, done_rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let r = (|| -> Result<String, String> {
                let encoders = Command::new(&ff).args(["-hide_banner", "-encoders"]).output().map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
                let (ext, args) = pick_codec(&encoders, bit_rate(dst.0, dst.1, fps)).ok_or("this ffmpeg has no H.264 or VP9 encoder")?;
                let name = format!("{stem}.{ext}");
                let mut enc = Encoder::start(&ff, &args, src, dst, fps, &dir.join(&name))?;
                *slot.lock().unwrap() = Some(enc.killer());
                let mut failed = None;
                for (frame, times) in rx {
                    for _ in 0..times {
                        if failed.is_none() {
                            if let Err(e) = enc.frame(frame.as_raw()) {
                                failed = Some(e);
                            }
                        }
                    }
                }
                let done = enc.finish(limit);
                match failed {
                    Some(e) => Err(e),
                    None => done.map(|_| name),
                }
                })();
                let _ = done_tx.send(r);
            });
            Some(done_rx)
        }
    };
    let frames_dir = plan.dir.join(format!("{}-frames", plan.stem));
    let _ = std::fs::remove_dir_all(&frames_dir);
    std::fs::create_dir_all(&frames_dir).map_err(|e| e.to_string())?;
    let mut stills: Vec<(f64, PathBuf)> = vec![];
    let mut thumbs: Vec<(f64, RgbaImage)> = vec![];
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
            if thumbs.last().map_or(true, |(s, _)| t - s >= 0.5 - 0.5 / fps as f64) {
                thumbs.push((t, fit(&frame, 480)));
            }
        }
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let next = Duration::from_secs_f64(written as f64 / fps as f64);
        if let Some(wait) = next.checked_sub(start.elapsed()) {
            std::thread::sleep(wait);
        }
        frame = Arc::new(grab()?);
    }
    // Up to the moment Stop was pressed, whatever the last grab cost.
    let due = (start.elapsed().as_secs_f64() * fps as f64) as u64;
    if writer.is_some() {
        offer(&mut pending, &last_good, due.saturating_sub(written));
        let deadline = Instant::now() + plan.finish_timeout;
        while pending.is_some() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            offer(&mut pending, &last_good, 0);
        }
    }
    written = written.max(due);
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
            Err(e) => problem = Some(e),
        }
    }

    // The stills that are kept: the macOS app's times, each from the nearest second taken.
    let have: Vec<f64> = stills.iter().map(|s| s.0).collect();
    let mut kept = vec![];
    for (i, want) in capture_math::still_times(duration, plan.max_stills).into_iter().enumerate() {
        let Some(j) = nearest(&have, want) else { continue };
        let name = format!("{:04}.jpg", i + 1);
        std::fs::copy(&stills[j].1, frames_dir.join(&name)).map_err(|e| e.to_string())?;
        kept.push(Still { time: (have[j] * 10.0).round() / 10.0, file: format!("{}-frames/{name}", plan.stem) });
    }
    for (_, p) in &stills {
        let _ = std::fs::remove_file(p);
    }

    let thumb_times: Vec<f64> = thumbs.iter().map(|t| t.0).collect();
    let tiles: Vec<(RgbaImage, f64)> = capture_math::sheet_times(duration, 16)
        .into_iter()
        .filter_map(|t| nearest(&thumb_times, t).map(|j| (thumbs[j].1.clone(), thumbs[j].0)))
        .collect();
    let sheet_name = format!("{}-contact.jpg", plan.stem);
    let sheet = match contact_sheet(&tiles) {
        Some(img) => {
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
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(2400));
            s2.store(true, Ordering::SeqCst);
        });
        let ff = with_ffmpeg();
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: ff.clone(), source: "test".into(), finish_timeout: Duration::from_secs(60) };
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
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(3000));
            s2.store(true, Ordering::SeqCst);
        });
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: Some(slow), source: "test".into(), finish_timeout: Duration::from_secs(60) };
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
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(3000));
            s2.store(true, Ordering::SeqCst);
        });
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: Some(slow), source: "test".into(), finish_timeout: Duration::from_secs(60) };
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
        let stop = Arc::new(AtomicBool::new(false));
        let s2 = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(12000));
            s2.store(true, Ordering::SeqCst);
        });
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: Some(stuck), source: "test".into(), finish_timeout: Duration::from_secs(2) };
        let t0 = Instant::now();
        // Big frames: the pipe and then the queue fill within the 12 seconds.
        let f = run(|| Ok(RgbaImage::from_pixel(1280, 720, Rgba([9, 9, 9, 255]))), plan, stop).unwrap();
        assert!(t0.elapsed() < Duration::from_secs(25), "Stop took {:?}", t0.elapsed());
        assert!(f.video.is_none() && f.problem.as_deref().unwrap_or("").contains("ffmpeg"), "{:?}", f.problem);
        assert!(f.duration >= 11.5, "{}", f.duration);
        assert!(dir.path().join("clip-001-frames/0012.jpg").is_file(), "the stills are kept");
    }

    #[test]
    fn without_ffmpeg_the_stills_still_come() {
        let dir = tempfile::tempdir().unwrap();
        let stop = Arc::new(AtomicBool::new(true));
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-002".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: None, source: "test".into(), finish_timeout: Duration::from_secs(60) };
        let f = run(|| Ok(RgbaImage::from_pixel(10, 10, Rgba([1, 2, 3, 255]))), plan, stop).unwrap();
        assert!(f.video.is_none());
        assert!(f.problem.unwrap().contains("ffmpeg"));
        assert!(dir.path().join("clip-002-frames/0001.jpg").is_file());
    }
}
