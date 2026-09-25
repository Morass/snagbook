// Page entry: the bridge first, then the editor (which mounts itself), then the shell.
import { attach } from "./bridge.js";
import "./editor/main.js";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { createShell } from "./shell.js";
import { runSelfTest } from "./selftest.js";

const shell = createShell({ invoke, snag: () => window.snag });
attach((msg) => shell.onEditorMessage(msg));
listen("captured", (e) => shell.onCaptured(e.payload));
listen("new-item", () => shell.newItem());
listen("problem", (e) => shell.flash(String(e.payload), true));
shell.start().then(async () => {
  if (await invoke("selftest_requested")) runSelfTest(shell, invoke);
});
