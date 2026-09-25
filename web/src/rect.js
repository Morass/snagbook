/// The rectangle between two points as fractions of a w×h window; null for a click (under
/// 4 pixels either way), which is not a rectangle.
export function rectFraction(a, b, w, h) {
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  const rw = Math.abs(b.x - a.x), rh = Math.abs(b.y - a.y);
  if (rw < 4 || rh < 4 || !w || !h) return null;
  return { x: x / w, y: y / h, w: rw / w, h: rh / h };
}
