// The mark-up window: highlight, circle, point at, box, write on, number, blur or crop a
// picture, then Done. The untouched original and the marks are kept beside the picture, so
// the marks can be changed later (double-click the picture in the note).
import { invoke } from "@tauri-apps/api/core";
import * as M from "./marks.js";
import { drawDocument, drawMark, font, renderDocument } from "./markrender.js";

const $ = (id) => document.getElementById(id);
const canvas = $("canvas");
const ctx = canvas.getContext("2d");
const windows = navigator.userAgent.includes("Windows");

const SYMBOL = { highlighter: "🖍", ellipse: "◯", arrow: "↗", rect: "▭", pen: "✎", text: "T", counter: "①", pixelate: "▦", crop: "⛶", select: "➚" };

let info = null;
let original = null;
let doc = null;
let tool = "highlighter";
const colors = { highlighter: M.PALETTE[1] };
let color = M.PALETTE[1];
let width = 4;
let opacity = 1;
let undoStack = [];
let redoStack = [];
let draft = null;
let cropDraft = null;
let dragStart = null;
let selected = null;
let moveFrom = null;
let movedOnce = false;
let editing = null; // { anchor, index }
let finished = false;

// ------------------------------------------------------------ editing

function commit(change) {
  undoStack.push(JSON.stringify(doc));
  if (undoStack.length > 200) undoStack.shift();
  redoStack = [];
  change(doc);
  draw();
}

function undo() {
  if (!undoStack.length) return;
  redoStack.push(JSON.stringify(doc));
  doc = JSON.parse(undoStack.pop());
  selected = null;
  draw();
}

function redo() {
  if (!redoStack.length) return;
  undoStack.push(JSON.stringify(doc));
  doc = JSON.parse(redoStack.pop());
  draw();
}

function setTool(t) {
  endText(true);
  tool = t;
  color = colors[t] || M.PALETTE[0];
  if (t !== "select") selected = null;
  canvas.style.cursor = t === "select" ? "default" : t === "text" ? "text" : "crosshair";
  renderBar();
  draw();
}

function setColor(c) {
  color = c;
  colors[tool] = c;
  if (tool === "select" && selected != null) commit((d) => (d.marks[selected].color = c));
  renderBar();
}

/// How solid new marks are; with Select, the selected mark's.
function setOpacity(o) {
  opacity = Math.min(1, Math.max(0.1, o));
  if (tool === "select" && selected != null && doc.marks[selected].tool !== "pixelate") commit((d) => (d.marks[selected].opacity = M.markOpacity(opacity)));
  renderBar();
}

function setWidth(w) {
  width = Math.max(1, Math.min(40, w));
  renderBar();
}

// ------------------------------------------------------------ drawing

function draw() {
  if (!doc) return;
  ctx.save();
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  drawDocument(ctx, doc, original);
  if (draft) drawMark(ctx, draft, original, doc);
  const crop = cropDraft || doc.crop;
  if (crop) {
    ctx.fillStyle = "rgba(0,0,0,0.45)";
    ctx.beginPath();
    ctx.rect(0, 0, doc.width, doc.height);
    ctx.rect(crop.x, crop.y + crop.h, crop.w, -crop.h);
    ctx.fill("evenodd");
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = Math.max(1, 1.5 / scale());
    ctx.setLineDash([6 / scale(), 4 / scale()]);
    ctx.strokeRect(crop.x, crop.y, crop.w, crop.h);
  }
  if (selected != null && doc.marks[selected]) {
    const b = M.bounds(doc.marks[selected]);
    ctx.strokeStyle = "#0a84ff";
    ctx.lineWidth = Math.max(1, 1.5 / scale());
    ctx.setLineDash([5 / scale(), 4 / scale()]);
    ctx.strokeRect(b.x - 4 / scale(), b.y - 4 / scale(), b.w + 8 / scale(), b.h + 8 / scale());
  }
  ctx.restore();
}

/// Screen (CSS) pixels per picture pixel.
const scale = () => canvas.getBoundingClientRect().width / canvas.width || 1;

function toImage(e) {
  const r = canvas.getBoundingClientRect();
  const k = canvas.width / r.width;
  const x = Math.max(0, Math.min(canvas.width, (e.clientX - r.left) * k));
  const y = Math.max(0, Math.min(canvas.height, (e.clientY - r.top) * k));
  return M.pt(x, y);
}

// ------------------------------------------------------------ mouse

// A mark may start beside the picture, as on the macOS app: it is clamped to the picture.
// Without preventDefault a drag from there would select the page and drag a copy of it.
$("stage").addEventListener("mousedown", (e) => {
  if (e.button !== 0 || !doc || e.target === textBox) return;
  e.preventDefault();
  const p = toImage(e);
  if (editing) {
    endText(true);
    if (tool === "text") return;
  }
  if (tool === "select") {
    selected = null;
    for (let i = doc.marks.length - 1; i >= 0; i--) if (M.hit(doc.marks[i], p, 6 / scale())) { selected = i; break; }
    // The slider shows the selected mark's opacity, so it can be changed from there.
    if (selected != null) {
      opacity = doc.marks[selected].opacity ?? 1;
      renderBar();
    }
    moveFrom = selected == null ? null : p;
    movedOnce = false;
    if (e.detail === 2 && selected != null && doc.marks[selected].tool === "text") beginText(doc.marks[selected].points[0], selected);
  } else if (tool === "crop") {
    dragStart = p;
    cropDraft = null;
  } else if (tool === "text") {
    beginText(p, null);
  } else if (tool === "counter") {
    const n = M.nextCounter(doc);
    commit((d) => d.marks.push({ tool: "counter", points: [p], color, width, number: n, opacity: M.markOpacity(opacity) }));
  } else {
    dragStart = p;
    draft = { tool, points: M.isPath(tool) ? [p] : [p, p], color: tool === "pixelate" ? "#000000" : color, width: tool === "highlighter" ? width * 4 : width, opacity: tool === "pixelate" ? null : M.markOpacity(opacity) };
  }
  draw();
});

addEventListener("mousemove", (e) => {
  if (!doc) return;
  const p = toImage(e);
  if (tool === "select" && selected != null && moveFrom && e.buttons & 1) {
    if (!movedOnce) commit(() => {});
    movedOnce = true;
    doc.marks[selected] = M.moved(doc.marks[selected], p.x - moveFrom.x, p.y - moveFrom.y);
    moveFrom = p;
    draw();
  } else if (tool === "crop" && dragStart) {
    cropDraft = M.spanning(dragStart, p);
    draw();
  } else if (draft) {
    if (M.isPath(draft.tool)) draft.points.push(p);
    else draft.points[1] = e.shiftKey ? M.constrain(dragStart, p, draft.tool) : p;
    draw();
  }
});

addEventListener("mouseup", () => {
  if (tool === "crop" && dragStart) {
    const c = cropDraft;
    if (c && c.w >= 8 && c.h >= 8) commit((d) => (d.crop = c));
    else if (doc.crop) commit((d) => (d.crop = null)); // a click with the crop tool removes the crop
    cropDraft = null;
    dragStart = null;
    draw();
    return;
  }
  moveFrom = null;
  if (!draft) return;
  const d = draft;
  draft = null;
  dragStart = null;
  if (M.isPath(d.tool)) d.points = M.simplify(d.points, Math.max(1, 1.5 / scale()));
  const big = M.isPath(d.tool) || M.dist(d.points[0], d.points[1]) >= 3;
  if (big) commit((doc) => doc.marks.push(d));
  else draw();
});

// ------------------------------------------------------------ text

const textBox = $("text");

function beginText(anchor, index) {
  endText(true);
  editing = { anchor, index };
  const m = index != null ? doc.marks[index] : null;
  const size = m ? m.width : M.textSize(width);
  const k = scale();
  const r = canvas.getBoundingClientRect();
  const stage = $("stage").getBoundingClientRect();
  textBox.hidden = false;
  textBox.value = m ? m.text : "";
  Object.assign(textBox.style, {
    left: r.left - stage.left + anchor.x * k + "px",
    top: r.top - stage.top + anchor.y * k + "px",
    font: font(size * k),
    color: m ? m.color : color,
    lineHeight: size * k * 1.25 + "px",
  });
  fitText();
  setTimeout(() => textBox.focus(), 0);
}

function fitText() {
  textBox.style.width = "0px";
  textBox.style.width = Math.max(60, textBox.scrollWidth + 8) + "px";
  textBox.rows = Math.max(1, textBox.value.split("\n").length);
}

function endText(keep) {
  if (!editing) return;
  const { anchor, index } = editing;
  editing = null;
  const text = textBox.value.trim();
  textBox.hidden = true;
  if (!keep) return draw();
  if (index != null) commit((d) => (text ? (d.marks[index].text = text) : d.marks.splice(index, 1)));
  else if (text) commit((d) => d.marks.push({ tool: "text", points: [anchor], color, width: M.textSize(width), text, opacity: M.markOpacity(opacity) }));
  else draw();
}

textBox.addEventListener("input", fitText);
textBox.addEventListener("keydown", (e) => {
  e.stopPropagation();
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    endText(true);
  } else if (e.key === "Escape") {
    e.preventDefault();
    endText(false);
  }
});

// ------------------------------------------------------------ keys

addEventListener("keydown", (e) => {
  if (!doc || editing) return;
  const mod = e.ctrlKey || e.metaKey;
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
  if (mod && k === "z") return e.preventDefault(), e.shiftKey ? redo() : undo();
  if (mod && k === "y") return e.preventDefault(), redo();
  if (mod && k === "Backspace" && info?.isNew) return e.preventDefault(), discard();
  if (mod || e.altKey) return;
  if (k === "Escape") {
    e.preventDefault();
    if (draft || cropDraft) {
      draft = cropDraft = dragStart = null;
      return draw();
    }
    return skip();
  }
  if (k === "Enter") return e.preventDefault(), done();
  if ((k === "Delete" || k === "Backspace") && selected != null) {
    e.preventDefault();
    const i = selected;
    selected = null;
    return commit((d) => d.marks.splice(i, 1));
  }
  const t = M.TOOLS.find((x) => x.key === k);
  if (t) return setTool(t.id);
  if (/^[1-6]$/.test(k)) return setColor(M.PALETTE[Number(k) - 1]);
  if (k === ",") return setOpacity(opacity - 0.1);
  if (k === ".") return setOpacity(opacity + 0.1);
  if (k === "[") return setWidth(width - 1);
  if (k === "]") return setWidth(width + 1);
});

// ------------------------------------------------------------ finishing

async function done() {
  if (finished) return;
  endText(true);
  finished = true;
  try {
    if (!doc.marks.length && !doc.crop) {
      await invoke("save_markup", { png: null, marks: null });
      return;
    }
    const out = renderDocument(doc, original, (w, h) => Object.assign(document.createElement("canvas"), { width: w, height: h }));
    const png = out.toDataURL("image/png").split(",")[1];
    await invoke("save_markup", { png, marks: M.encodeDocument(doc) });
  } catch (e) {
    finished = false;
    alert("The picture could not be saved: " + (e?.message || e));
  }
}

function skip() {
  if (finished) return;
  finished = true;
  invoke("skip_markup");
}

function discard() {
  if (finished) return;
  finished = true;
  invoke("discard_markup");
}

// ------------------------------------------------------------ the bar

function renderBar() {
  const tools = $("tools");
  tools.textContent = "";
  for (const t of M.TOOLS) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = SYMBOL[t.id];
    b.title = `${t.title}  ${t.key.toUpperCase()}`;
    b.dataset.tool = t.id;
    b.className = t.id === tool ? "on" : "";
    b.addEventListener("click", () => setTool(t.id));
    tools.append(b);
  }
  const cs = $("colors");
  cs.textContent = "";
  M.PALETTE.forEach((c, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "swatch" + (c === color ? " on" : "");
    b.style.background = c;
    b.title = `Colour ${i + 1}`;
    b.addEventListener("click", () => setColor(c));
    cs.append(b);
  });
  $("width").textContent = String(width);
  $("opacity").value = String(Math.round(opacity * 100));
  $("opacity-n").textContent = Math.round(opacity * 100) + "%";
}

$("thinner").addEventListener("click", () => setWidth(width - 1));
$("opacity").addEventListener("input", (e) => setOpacity(Number(e.target.value) / 100));
// Keys go to the picture, not the slider, once it has been dragged.
$("opacity").addEventListener("change", () => $("opacity").blur());
$("thicker").addEventListener("click", () => setWidth(width + 1));
$("undo").addEventListener("click", undo);
$("done").addEventListener("click", done);
$("skip").addEventListener("click", skip);
$("discard").addEventListener("click", discard);
addEventListener("resize", draw);

// ------------------------------------------------------------ start

function load(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    // The picture comes from the app's own scheme, another origin: without this the canvas
    // it is drawn on could not be saved.
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("the picture could not be read"));
    img.src = src;
  });
}

async function start() {
  info = await invoke("markup_info");
  const base = (windows ? "http://snagbook.localhost" : "snagbook://localhost") + `/item/${info.id}/`;
  const comp = M.companions(info.rel);
  original = await load(base + (info.hasOrig ? comp.orig : info.rel).split("/").map(encodeURIComponent).join("/") + "?v=" + Date.now());
  canvas.width = original.naturalWidth;
  canvas.height = original.naturalHeight;
  doc = (info.marks && M.parseDocument(info.marks, canvas.width, canvas.height)) || M.newDocument(canvas.width, canvas.height);
  width = M.defaultWidth(canvas.width, canvas.height);
  document.title = "Mark up — " + info.rel.split("/").pop();
  $("discard").hidden = !info.isNew;
  $("discard").title = "Discard: throw this screenshot away  Ctrl+Backspace";
  $("skip").title = info.isNew ? "No marks: keep the screenshot as it is  Esc" : "Cancel: keep the picture as it was  Esc";
  $("done").title = "Done: save the marks  Enter";
  $("undo").title = "Undo  Ctrl+Z";
  renderBar();
  draw();
  if (info.auto) autotest(info.auto);
}

/// The self-test's hands: draw something known and finish, as a person would.
function autotest(script) {
  const W = doc.width, H = doc.height;
  if (script === "ring") {
    commit((d) => d.marks.push({ tool: "ellipse", points: [M.pt(W * 0.2, H * 0.2), M.pt(W * 0.8, H * 0.8)], color: "#ff3b30", width: 6 }));
    setTimeout(done, 200);
  } else if (script === "count") {
    commit((d) => d.marks.push({ tool: "counter", points: [M.pt(W * 0.5, H * 0.5)], color: "#0a84ff", width: 4, number: M.nextCounter(d) }));
    setTimeout(done, 200);
  } else if (script === "clear") {
    commit((d) => (d.marks = []));
    setTimeout(done, 200);
  } else if (script === "skip") setTimeout(skip, 200);
  else if (script === "discard") setTimeout(discard, 200);
}

start().catch((e) => {
  document.body.textContent = "This picture could not be opened: " + (e?.message || e);
});

addEventListener("dragstart", (e) => e.preventDefault());
