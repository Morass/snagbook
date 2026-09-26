// Marks on a picture: the same model and file format as the macOS app's Marks.swift, so a
// picture marked up on one system can be changed on the other. Coordinates are image pixels,
// origin top-left. Stored as "<name>.marks.json" beside "<name>.orig.png" (the untouched
// picture) and the rendered "<name>.png".

export const TOOLS = [
  { id: "highlighter", key: "h", title: "Highlighter" },
  { id: "ellipse", key: "o", title: "Circle" },
  { id: "arrow", key: "a", title: "Arrow" },
  { id: "rect", key: "r", title: "Box" },
  { id: "pen", key: "p", title: "Pen" },
  { id: "text", key: "t", title: "Text" },
  { id: "counter", key: "n", title: "Number" },
  { id: "pixelate", key: "b", title: "Blur" },
  { id: "crop", key: "c", title: "Crop" },
  { id: "select", key: "v", title: "Select" },
];

export const PALETTE = ["#ff3b30", "#ffcc00", "#34c759", "#0a84ff", "#ffffff", "#000000"];

export const isTwoPoint = (tool) => ["arrow", "ellipse", "rect", "pixelate"].includes(tool);
export const isPath = (tool) => tool === "pen" || tool === "highlighter";

export const pt = (x, y) => ({ x, y });
export const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

export function spanning(a, b) {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) };
}
export const inset = (b, d) => ({ x: b.x + d, y: b.y + d, w: b.w - 2 * d, h: b.h - 2 * d });
export const contains = (b, p) => p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h;
export const isEmpty = (b) => b.w <= 0 || b.h <= 0;

export function intersection(a, o) {
  const x0 = Math.max(a.x, o.x), y0 = Math.max(a.y, o.y);
  const x1 = Math.min(a.x + a.w, o.x + o.w), y1 = Math.min(a.y + a.h, o.y + o.h);
  return x1 > x0 && y1 > y0 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : { x: 0, y: 0, w: 0, h: 0 };
}

export function union(a, o) {
  if (isEmpty(a)) return o;
  if (isEmpty(o)) return a;
  const x0 = Math.min(a.x, o.x), y0 = Math.min(a.y, o.y);
  return { x: x0, y: y0, w: Math.max(a.x + a.w, o.x + o.w) - x0, h: Math.max(a.y + a.h, o.y + o.h) - y0 };
}

export function distanceToSegment(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) return dist(p, a);
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  return dist(p, pt(a.x + t * dx, a.y + t * dy));
}

export const counterRadius = (m) => Math.max(12, m.width * 3.2);

export function bounds(m) {
  const first = m.points[0];
  if (!first) return { x: 0, y: 0, w: 0, h: 0 };
  if (m.tool === "text") {
    const lines = (m.text || "").split("\n");
    const longest = Math.max(1, ...lines.map((l) => l.length));
    return { x: first.x, y: first.y, w: longest * m.width * 0.6, h: Math.max(1, lines.length) * m.width * 1.25 };
  }
  if (m.tool === "counter") {
    const r = counterRadius(m);
    return { x: first.x - r, y: first.y - r, w: 2 * r, h: 2 * r };
  }
  let b = { x: first.x, y: first.y, w: 0, h: 0 };
  for (const p of m.points.slice(1)) b = union(b, { x: p.x, y: p.y, w: 0.0001, h: 0.0001 });
  return inset(b, -m.width);
}

/// True when `p` is on (or within `tolerance` of) the mark.
export function hit(m, p, tolerance) {
  const tol = tolerance + m.width / 2;
  const [a, b] = m.points;
  switch (m.tool) {
    case "rect":
    case "pixelate": {
      if (!b) return false;
      const box = spanning(a, b);
      if (m.tool === "pixelate") return contains(inset(box, -tol), p);
      return contains(inset(box, -tol), p) && !contains(inset(box, tol), p);
    }
    case "ellipse": {
      if (!b) return false;
      const box = spanning(a, b);
      const rx = box.w / 2, ry = box.h / 2;
      if (!(rx > 0 && ry > 0)) return false;
      const cx = box.x + rx, cy = box.y + ry;
      const d = ((p.x - cx) ** 2) / (rx * rx) + ((p.y - cy) ** 2) / (ry * ry);
      return Math.abs(Math.sqrt(d) - 1) <= tol / Math.min(rx, ry);
    }
    case "arrow":
      return !!b && distanceToSegment(p, a, b) <= tol;
    case "pen":
    case "highlighter":
      if (m.points.length === 1) return dist(p, a) <= tol;
      for (let i = 1; i < m.points.length; i++) if (distanceToSegment(p, m.points[i - 1], m.points[i]) <= tol) return true;
      return false;
    default:
      return contains(inset(bounds(m), -tolerance), p);
  }
}

export const moved = (m, dx, dy) => ({ ...m, points: m.points.map((p) => pt(p.x + dx, p.y + dy)) });

/// Shift-constrain a drag: squares and circles, or arrows snapped to 45°.
export function constrain(start, end, tool) {
  const dx = end.x - start.x, dy = end.y - start.y;
  if (tool === "arrow") {
    const step = Math.PI / 4;
    const snapped = Math.round(Math.atan2(dy, dx) / step) * step;
    const len = Math.hypot(dx, dy);
    return pt(start.x + Math.cos(snapped) * len, start.y + Math.sin(snapped) * len);
  }
  const side = Math.max(Math.abs(dx), Math.abs(dy));
  return pt(start.x + (dx < 0 ? -side : side), start.y + (dy < 0 ? -side : side));
}

/// The two barbs of an arrow head at `tip`, for a shaft coming from `tail`.
export function arrowHead(tail, tip, width) {
  const angle = Math.atan2(tip.y - tail.y, tip.x - tail.x);
  const len = Math.min(Math.max(width * 4.5, 14), Math.max(dist(tail, tip) * 0.6, 6));
  const spread = Math.PI / 7;
  return [
    pt(tip.x - len * Math.cos(angle - spread), tip.y - len * Math.sin(angle - spread)),
    pt(tip.x - len * Math.cos(angle + spread), tip.y - len * Math.sin(angle + spread)),
  ];
}

/// Drop path samples closer than `minStep` to the previous kept one; keep both ends.
export function simplify(pts, minStep) {
  if (!pts.length) return [];
  let last = pts[0];
  const out = [last];
  for (const p of pts.slice(1)) {
    if (dist(p, last) >= minStep) {
      out.push(p);
      last = p;
    }
  }
  const end = pts[pts.length - 1];
  if (out[out.length - 1] !== end) out.push(end);
  return out;
}

export function newDocument(width, height) {
  return { version: 1, width, height, crop: null, marks: [] };
}

export const nextCounter = (doc) => Math.max(0, ...doc.marks.map((m) => m.number || 0)) + 1;

/// The crop, clamped to the picture, or the whole picture.
export function outputBox(doc) {
  const full = { x: 0, y: 0, w: doc.width, h: doc.height };
  if (!doc.crop) return full;
  const c = intersection(doc.crop, full);
  return c.w >= 4 && c.h >= 4 ? { x: Math.round(c.x), y: Math.round(c.y), w: Math.round(c.w), h: Math.round(c.h) } : full;
}

/// The marks file and original that belong to a rendered picture "media/shot-001.png".
export function companions(relative) {
  const stem = relative.endsWith(".png") ? relative.slice(0, -4) : relative;
  return { orig: stem + ".orig.png", marks: stem + ".marks.json" };
}

/// A document read from a marks file, or null when it does not fit the picture.
export function parseDocument(json, width, height) {
  try {
    const d = typeof json === "string" ? JSON.parse(json) : json;
    if (!d || d.width !== width || d.height !== height || !Array.isArray(d.marks)) return null;
    return { version: d.version || 1, width, height, crop: d.crop || null, marks: d.marks };
  } catch {
    return null;
  }
}

/// JSON as the macOS app writes it: sorted keys, no null crop, no empty optional fields.
export function encodeDocument(doc) {
  const sortKeys = (v) =>
    Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().filter((k) => v[k] !== null && v[k] !== undefined).map((k) => [k, sortKeys(v[k])])) : v;
  return JSON.stringify(sortKeys(doc), null, 2);
}

/// Stroke width that looks the same on any picture size.
export const defaultWidth = (w, h) => Math.min(12, Math.round(Math.max(3, Math.max(w, h) / 320)));
/// Font size of a new text mark.
export const textSize = (width) => Math.max(18, width * 5);
