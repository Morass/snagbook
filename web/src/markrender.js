// Drawing marks on a 2D canvas. The same routine paints the live canvas and the saved
// picture, so what you see while marking up is what gets saved. Mirrors the macOS app's
// MarkRenderer: shadows, the highlighter's multiply, outlined text, numbered counters.
import { arrowHead, counterRadius, dist, intersection, isEmpty, outputBox, spanning } from "./marks.js";

export function rgb(hex) {
  let s = String(hex || "").trim().replace(/^#/, "");
  if (s.length === 3) s = [...s].map((c) => c + c).join("");
  const v = /^[0-9a-f]{6}$/i.test(s) ? parseInt(s, 16) : null;
  return v === null ? [255, 51, 51] : [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

const luminance = ([r, g, b]) => (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
export const contrasting = (hex) => (luminance(rgb(hex)) > 0.6 ? "#000000" : "#ffffff");
const rgba = (hex, a) => `rgba(${rgb(hex).join(",")},${a})`;

const FONT = 'bold {size}px system-ui, -apple-system, "Segoe UI", Ubuntu, sans-serif';
export const font = (size) => FONT.replace("{size}", String(size));

function shadow(ctx, body) {
  ctx.save();
  ctx.shadowOffsetX = 0;
  ctx.shadowOffsetY = 1;
  ctx.shadowBlur = 3;
  ctx.shadowColor = "rgba(0,0,0,0.35)";
  body();
  ctx.restore();
}

function smoothPath(ctx, pts) {
  ctx.moveTo(pts[0].x, pts[0].y);
  if (pts.length === 1) return ctx.lineTo(pts[0].x + 0.01, pts[0].y);
  if (pts.length === 2) return ctx.lineTo(pts[1].x, pts[1].y);
  for (let i = 1; i < pts.length - 1; i++) {
    ctx.quadraticCurveTo(pts[i].x, pts[i].y, (pts[i].x + pts[i + 1].x) / 2, (pts[i].y + pts[i + 1].y) / 2);
  }
  ctx.lineTo(pts[pts.length - 1].x, pts[pts.length - 1].y);
}

/// Pixelate a region of `original` onto `ctx`: blocks of max(6, short side / 10) pixels.
function pixelate(ctx, original, box, doc) {
  const b = intersection(box, { x: 0, y: 0, w: doc.width, h: doc.height });
  if (isEmpty(b)) return;
  const x = Math.floor(b.x), y = Math.floor(b.y), w = Math.ceil(b.w), h = Math.ceil(b.h);
  const block = Math.max(6, Math.min(w, h) / 10);
  const sw = Math.max(1, Math.round(w / block)), sh = Math.max(1, Math.round(h / block));
  const small = ctx.canvas.ownerDocument ? ctx.canvas.ownerDocument.createElement("canvas") : new OffscreenCanvas(sw, sh);
  small.width = sw;
  small.height = sh;
  const s = small.getContext("2d");
  s.imageSmoothingEnabled = true;
  s.drawImage(original, x, y, w, h, 0, 0, sw, sh);
  ctx.save();
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(small, 0, 0, sw, sh, x, y, w, h);
  ctx.restore();
}

/// A see-through mark is drawn whole on its own layer, then laid on at its opacity, so
/// overlapping parts (an arrow's head and shaft, text's outline) do not double up — as the
/// macOS app's transparency layer does.
export function drawMark(ctx, m, original, doc) {
  const alpha = Math.min(1, Math.max(0.1, m.opacity ?? 1));
  if (alpha >= 1 || m.tool === "pixelate") return drawSolid(ctx, m, original, doc);
  const layer = ctx.canvas.ownerDocument.createElement("canvas");
  layer.width = ctx.canvas.width;
  layer.height = ctx.canvas.height;
  const l = layer.getContext("2d");
  l.setTransform(ctx.getTransform());
  drawSolid(l, m, original, doc);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = alpha;
  // A highlighter tints what is under it (black text stays black), see-through or not.
  if (m.tool === "highlighter") ctx.globalCompositeOperation = "multiply";
  ctx.drawImage(layer, 0, 0);
  ctx.restore();
}

function drawSolid(ctx, m, original, doc) {
  const color = m.color;
  ctx.save();
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = m.width;
  const [a, b] = m.points;
  switch (m.tool) {
    case "rect":
      if (b) {
        const r = spanning(a, b);
        shadow(ctx, () => ctx.strokeRect(r.x, r.y, r.w, r.h));
      }
      break;
    case "ellipse":
      if (b) {
        const r = spanning(a, b);
        shadow(ctx, () => {
          ctx.beginPath();
          ctx.ellipse(r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2, 0, 0, Math.PI * 2);
          ctx.stroke();
        });
      }
      break;
    case "arrow":
      if (b) {
        const [b1, b2] = arrowHead(a, b, m.width);
        // Shorten the shaft so its round cap does not poke through the head.
        const back = dist(a, b) > m.width * 2 ? m.width * 1.2 : 0;
        const angle = Math.atan2(b.y - a.y, b.x - a.x);
        shadow(ctx, () => {
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x - back * Math.cos(angle), b.y - back * Math.sin(angle));
          ctx.stroke();
          ctx.beginPath();
          ctx.moveTo(b.x, b.y);
          ctx.lineTo(b1.x, b1.y);
          ctx.lineTo(b2.x, b2.y);
          ctx.closePath();
          ctx.fill();
        });
      }
      break;
    case "pen":
    case "highlighter":
      if (a) {
        if (m.tool === "highlighter") {
          ctx.globalCompositeOperation = "multiply";
          ctx.strokeStyle = rgba(color, 0.42);
          ctx.lineCap = "square";
        }
        ctx.beginPath();
        smoothPath(ctx, m.points);
        if (m.tool === "pen") shadow(ctx, () => ctx.stroke());
        else ctx.stroke();
      }
      break;
    case "text":
      if (a && m.text) {
        ctx.font = font(m.width);
        ctx.textBaseline = "top";
        ctx.lineJoin = "round";
        ctx.lineWidth = m.width * 0.14;
        ctx.strokeStyle = luminance(rgb(color)) > 0.6 ? "rgba(0,0,0,0.9)" : "rgba(255,255,255,0.95)";
        m.text.split("\n").forEach((line, i) => {
          if (!line) return;
          const y = a.y + i * m.width * 1.25;
          ctx.strokeText(line, a.x, y);
          ctx.fillText(line, a.x, y);
        });
      }
      break;
    case "counter":
      if (a) {
        const r = counterRadius(m);
        shadow(ctx, () => {
          ctx.beginPath();
          ctx.arc(a.x, a.y, r, 0, Math.PI * 2);
          ctx.fill();
        });
        ctx.strokeStyle = "#ffffff";
        ctx.lineWidth = Math.max(1.5, r * 0.12);
        ctx.beginPath();
        ctx.arc(a.x, a.y, r - 0.5, 0, Math.PI * 2);
        ctx.stroke();
        ctx.fillStyle = contrasting(color);
        ctx.font = font(r * 1.15);
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(String(m.number ?? 1), a.x, a.y + r * 0.05);
      }
      break;
    case "pixelate":
      if (b && original) pixelate(ctx, original, spanning(a, b), doc);
      break;
  }
  ctx.restore();
}

/// Draw the whole document (picture and marks) on `ctx` in image pixels.
export function drawDocument(ctx, doc, original) {
  ctx.drawImage(original, 0, 0, doc.width, doc.height);
  for (const m of doc.marks) drawMark(ctx, m, original, doc);
}

/// The finished picture: the original, cropped, with every mark drawn on it.
export function renderDocument(doc, original, makeCanvas) {
  const out = outputBox(doc);
  const c = makeCanvas(out.w, out.h);
  const ctx = c.getContext("2d");
  ctx.translate(-out.x, -out.y);
  drawDocument(ctx, doc, original);
  return c;
}
