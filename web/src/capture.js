// The screenshot window: the frozen screen, full size. Drag a rectangle to keep it.
import { invoke } from "@tauri-apps/api/core";
import { rectFraction } from "./rect.js";

const windows = navigator.userAgent.includes("Windows");
const recording = new URLSearchParams(location.search).get("mode") === "record";
if (recording) document.getElementById("hint").textContent = "Drag the area to record · Enter for the whole screen · Esc to cancel";
const frame = document.getElementById("frame");
const sel = document.getElementById("sel");
const size = document.getElementById("size");
let start = null;
let done = false;

frame.src = (windows ? "http://snagbook.localhost" : "snagbook://localhost") + "/capture/frame.png";

function finish(rect) {
  if (done) return;
  done = true;
  invoke("finish_screenshot", { rect }).catch(() => invoke("cancel_screenshot"));
}

function cancel() {
  if (done) return;
  done = true;
  invoke("cancel_screenshot");
}

addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  start = { x: e.clientX, y: e.clientY };
  document.body.classList.add("dragging");
});

addEventListener("mousemove", (e) => {
  if (!start) return;
  const x = Math.min(start.x, e.clientX), y = Math.min(start.y, e.clientY);
  const w = Math.abs(e.clientX - start.x), h = Math.abs(e.clientY - start.y);
  Object.assign(sel.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
  sel.hidden = false;
  const k = frame.naturalWidth ? frame.naturalWidth / innerWidth : devicePixelRatio;
  size.textContent = `${Math.round(w * k)} × ${Math.round(h * k)}`;
});

addEventListener("mouseup", (e) => {
  if (!start) return;
  const r = rectFraction(start, { x: e.clientX, y: e.clientY }, innerWidth, innerHeight);
  start = null;
  if (r) finish(r);
  else {
    sel.hidden = true;
    document.body.classList.remove("dragging");
  }
});

addEventListener("keydown", (e) => {
  if (e.key === "Escape") cancel();
  else if (e.key === "Enter") finish({ x: 0, y: 0, w: 1, h: 1 });
});

addEventListener("contextmenu", (e) => {
  e.preventDefault();
  cancel();
});
