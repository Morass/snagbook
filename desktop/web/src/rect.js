/// The rectangle between two points as fractions of a w×h window; null for a click (under
/// 4 pixels either way), which is not a rectangle.
export function rectFraction(a, b, w, h) {
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  const rw = Math.abs(b.x - a.x), rh = Math.abs(b.y - a.y);
  if (rw < 4 || rh < 4 || !w || !h) return null;
  return { x: x / w, y: y / h, w: rw / w, h: rh / h };
}

/// "0:07", "1:05", "1:00:03": the recording timer.
export function formatElapsed(s) {
  const t = Math.max(0, Math.floor(s));
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60;
  const two = (n) => String(n).padStart(2, "0");
  return h ? `${h}:${two(m)}:${two(sec)}` : `${m}:${two(sec)}`;
}
