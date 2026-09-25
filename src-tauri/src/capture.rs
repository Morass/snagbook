//! Screenshots: freeze the screen under the mouse, show that frame full-screen in a window
//! of its own, and let the person drag the rectangle they want. The frozen frame is what
//! gets saved, so nothing that moves while they drag ends up in the picture.

use image::{codecs::png::PngEncoder, ExtendedColorType, ImageEncoder, RgbaImage};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

pub const WINDOW: &str = "capture";

/// The frame being cropped, while the capture window is open.
#[derive(Default)]
pub struct Frozen(pub Mutex<Option<Frame>>);

pub struct Frame {
    pub image: RgbaImage,
    pub png: Vec<u8>,
    pub mode: Mode,
    /// A point inside the photographed monitor, to find it again for a recording.
    pub center: (i32, i32),
    /// The monitor's position and size in physical pixels.
    pub monitor: (i32, i32, u32, u32),
}

/// What the rectangle is for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Screenshot,
    Record,
}

/// A rectangle as fractions of the frozen frame (0..1), so window scaling does not matter.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Clone, Serialize)]
pub struct Captured {
    pub id: i64,
    pub rel: String,
    /// "image" or "video".
    pub kind: String,
    pub label: String,
    /// Said to the person after a recording that could not be saved in full.
    pub problem: Option<String>,
}

/// The pixel rectangle `r` covers in a `width`×`height` frame, clamped inside it; None when
/// it is smaller than 2×2 pixels.
pub fn pixels(r: Rect, width: u32, height: u32) -> Option<(u32, u32, u32, u32)> {
    let clamp = |v: f64| if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
    let (x0, y0) = (clamp(r.x.min(r.x + r.w)), clamp(r.y.min(r.y + r.h)));
    let (x1, y1) = (clamp(r.x.max(r.x + r.w)), clamp(r.y.max(r.y + r.h)));
    let px = |f: f64, n: u32| (f * n as f64).round() as u32;
    let (a, b, c, d) = (px(x0, width), px(y0, height), px(x1, width), px(y1, height));
    (c.saturating_sub(a) >= 2 && d.saturating_sub(b) >= 2).then(|| (a, b, c - a, d - b))
}

pub fn encode_png(img: &RgbaImage, fast: bool) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let enc = if fast {
        PngEncoder::new_with_quality(&mut out, image::codecs::png::CompressionType::Fast, image::codecs::png::FilterType::NoFilter)
    } else {
        PngEncoder::new(&mut out)
    };
    enc.write_image(img.as_raw(), img.width(), img.height(), ExtendedColorType::Rgba8).map_err(|e| e.to_string())?;
    Ok(out)
}

/// Photograph the monitor under the mouse and open the window that crops it.
pub fn start(app: &AppHandle, mode: Mode) -> Result<(), String> {
    if let Some(w) = app.get_webview_window(WINDOW) {
        let _ = w.set_focus();
        return Ok(());
    }
    let cursor = app.cursor_position().unwrap_or_default();
    let monitors = app.available_monitors().map_err(|e| e.to_string())?;
    let inside = |m: &tauri::Monitor| {
        let (p, s) = (m.position(), m.size());
        cursor.x >= p.x as f64 && cursor.y >= p.y as f64 && cursor.x < (p.x + s.width as i32) as f64 && cursor.y < (p.y + s.height as i32) as f64
    };
    let target = monitors.iter().find(|m| inside(m)).or(monitors.first()).cloned().ok_or("No screen was found.")?;
    let (pos, size) = (*target.position(), *target.size());

    let center = (pos.x + size.width as i32 / 2, pos.y + size.height as i32 / 2);
    let monitor = match xcap::Monitor::from_point(center.0, center.1) {
        Ok(m) => m,
        Err(_) => xcap::Monitor::all().map_err(|e| format!("The screen could not be read: {e}"))?.into_iter().next().ok_or("No screen was found.")?,
    };
    let shot = monitor.capture_image().map_err(|e| format!("The screen could not be photographed: {e}"))?;
    let (w, h) = (shot.width(), shot.height());
    let image = RgbaImage::from_raw(w, h, shot.into_raw()).ok_or("The screen picture was malformed.")?;
    let png = encode_png(&image, true)?;
    *app.state::<Frozen>().0.lock().unwrap() = Some(Frame { image, png, mode, center, monitor: (pos.x, pos.y, size.width, size.height) });

    let page = if mode == Mode::Record { "capture.html?mode=record" } else { "capture.html" };
    let win = WebviewWindowBuilder::new(app, WINDOW, WebviewUrl::App(page.into()))
        .title("Snagbook screenshot")
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())?;
    let _ = win.set_position(PhysicalPosition::new(pos.x, pos.y));
    let _ = win.set_size(PhysicalSize::new(size.width, size.height));
    let _ = win.set_fullscreen(true);
    let _ = win.show();
    let _ = win.set_focus();
    Ok(())
}

pub fn close(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(WINDOW) {
        let _ = w.destroy();
    }
    *app.state::<Frozen>().0.lock().unwrap() = None;
}

/// What the rectangle chose.
pub enum Chosen {
    /// A screenshot's PNG.
    Picture(Vec<u8>),
    /// A region to record: a point on its monitor, and the rectangle in that monitor's
    /// captured pixels.
    Region { center: (i32, i32), rect: (u32, u32, u32, u32), monitor: (i32, i32, u32, u32) },
}

/// Take the frozen frame and close the capture window.
pub fn finish(app: &AppHandle, r: Rect) -> Result<Chosen, String> {
    let frame = app.state::<Frozen>().0.lock().unwrap().take().ok_or("No screenshot is in progress.")?;
    close(app);
    let rect = pixels(r, frame.image.width(), frame.image.height()).ok_or("The rectangle was too small.")?;
    match frame.mode {
        Mode::Record => Ok(Chosen::Region { center: frame.center, rect, monitor: frame.monitor }),
        Mode::Screenshot => {
            let (x, y, w, h) = rect;
            let crop = image::imageops::crop_imm(&frame.image, x, y, w, h).to_image();
            Ok(Chosen::Picture(encode_png(&crop, false)?))
        }
    }
}

pub fn announce(app: &AppHandle, c: Captured) {
    let _ = app.emit_to("main", "captured", c);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rectangles_become_pixels() {
        let r = |x, y, w, h| Rect { x, y, w, h };
        assert_eq!(pixels(r(0.1, 0.1, 0.25, 0.2), 1280, 800), Some((128, 80, 320, 160)));
        assert_eq!(pixels(r(0.5, 0.5, -0.25, -0.25), 100, 100), Some((25, 25, 25, 25)), "dragged up and left");
        assert_eq!(pixels(r(0.9, 0.9, 0.5, 0.5), 100, 100), Some((90, 90, 10, 10)), "clamped at the edge");
        assert_eq!(pixels(r(0.0, 0.0, 1.0, 1.0), 1920, 1080), Some((0, 0, 1920, 1080)));
        assert_eq!(pixels(r(0.5, 0.5, 0.001, 0.001), 100, 100), None, "a click is not a rectangle");
        assert_eq!(pixels(r(f64::NAN, 0.0, 0.5, 0.5), 100, 100), None);
    }

    #[test]
    fn png_round_trip() {
        let img = RgbaImage::from_pixel(3, 2, image::Rgba([10, 20, 30, 255]));
        let png = encode_png(&img, false).unwrap();
        assert_eq!(&png[1..4], b"PNG");
        assert_eq!(u32::from_be_bytes(png[16..20].try_into().unwrap()), 3);
        assert_eq!(u32::from_be_bytes(png[20..24].try_into().unwrap()), 2);
    }
}
