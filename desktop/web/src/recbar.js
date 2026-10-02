// The floating timer while a recording runs; Stop ends it.
import { invoke } from "@tauri-apps/api/core";
import { formatElapsed } from "./rect.js";

const time = document.getElementById("time");
let started = null;
invoke("recording_started").then((ms) => (started = ms));
setInterval(() => {
  if (started) time.textContent = formatElapsed((Date.now() - started) / 1000);
}, 250);
document.getElementById("stop").addEventListener("click", () => invoke("stop_recording"));
