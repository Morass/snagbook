// Bundles the editor into ../Resources/editor, which the app loads offline.
import { build } from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";

const out = new URL("../Resources/editor/", import.meta.url).pathname;
mkdirSync(out, { recursive: true });
await build({
  entryPoints: ["src/main.js"],
  bundle: true,
  minify: false,
  format: "iife",
  target: ["safari17"],
  outfile: out + "editor.js",
  legalComments: "eof",
});
copyFileSync("src/index.html", out + "index.html");
copyFileSync("src/editor.css", out + "editor.css");
console.log("built", out);
