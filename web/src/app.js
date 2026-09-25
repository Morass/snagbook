// Page entry: the bridge first, then the editor (which mounts itself), then the shell.
import { attach } from "./bridge.js";
import "./editor/main.js";
import { invoke } from "@tauri-apps/api/core";
import { createShell } from "./shell.js";
import { runSelfTest } from "./selftest.js";

const shell = createShell({ invoke, snag: () => window.snag });
attach((msg) => shell.onEditorMessage(msg));
shell.start().then(async () => {
  if (await invoke("selftest_requested")) runSelfTest(shell, invoke);
});
