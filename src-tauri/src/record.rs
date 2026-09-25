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
    child: Child,
    stdin: Option<ChildStdin>,
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
        Ok(Encoder { child, stdin })
    }

    pub fn frame(&mut self, rgba: &[u8]) -> Result<(), String> {
        self.stdin.as_mut().ok_or("ffmpeg has stopped")?.write_all(rgba).map_err(|e| format!("ffmpeg stopped taking frames: {e}"))
    }

    pub fn finish(mut self) -> Result<(), String> {
        drop(self.stdin.take());
        let out = self.child.wait_with_output().map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            Err(format!("ffmpeg failed: {}", String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("")))
        }
    }
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
    let mut video: Option<(Encoder, String)> = None;
    if let Some(ff) = &plan.ffmpeg {
        let encoders = Command::new(ff).args(["-hide_banner", "-encoders"]).output().map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
        match pick_codec(&encoders, bit_rate(dst.0, dst.1, fps)) {
            Some((ext, args)) => {
                let name = format!("{}.{ext}", plan.stem);
                match Encoder::start(ff, &args, src, dst, fps, &plan.dir.join(&name)) {
                    Ok(e) => video = Some((e, name)),
                    Err(e) => problem = Some(e),
                }
            }
            None => problem = Some("this ffmpeg has no H.264 or VP9 encoder".into()),
        }
    } else {
        problem = Some("ffmpeg was not found, so only the stills and the contact sheet were saved".into());
    }

    let frames_dir = plan.dir.join(format!("{}-frames", plan.stem));
    let _ = std::fs::remove_dir_all(&frames_dir);
    std::fs::create_dir_all(&frames_dir).map_err(|e| e.to_string())?;
    let mut stills: Vec<(f64, PathBuf)> = vec![];
    let mut thumbs: Vec<(f64, RgbaImage)> = vec![];
    let start = Instant::now();
    let mut written: u64 = 0;
    let mut frame = first;
    loop {
        let t = start.elapsed().as_secs_f64();
        if frame.dimensions() == src {
            // Keep the video's clock: a slow grab repeats the frame instead of speeding up time.
            let due = (t * fps as f64) as u64 + 1;
            while written < due {
                if let Some((enc, _)) = video.as_mut() {
                    if let Err(e) = enc.frame(frame.as_raw()) {
                        problem = Some(e);
                        video = None;
                    }
                }
                written += 1;
            }
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
        frame = grab()?;
    }
    let duration = written as f64 / fps as f64;

    let video_name = match video {
        Some((enc, name)) => match enc.finish() {
            Ok(()) => Some(name),
            Err(e) => {
                problem = Some(e);
                None
            }
        },
        None => None,
    };

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
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-001".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: ff.clone(), source: "test".into() };
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

    #[test]
    fn without_ffmpeg_the_stills_still_come() {
        let dir = tempfile::tempdir().unwrap();
        let stop = Arc::new(AtomicBool::new(true));
        let plan = Plan { dir: dir.path().to_path_buf(), stem: "clip-002".into(), fps: 15, max_long_edge: 1920, max_stills: 60, ffmpeg: None, source: "test".into() };
        let f = run(|| Ok(RgbaImage::from_pixel(10, 10, Rgba([1, 2, 3, 255]))), plan, stop).unwrap();
        assert!(f.video.is_none());
        assert!(f.problem.unwrap().contains("ffmpeg"));
        assert!(dir.path().join("clip-002-frames/0001.jpg").is_file());
    }
}
