// Bundles the page into web/dist, which the app loads offline.
import { build } from "esbuild";
import { copyFileSync, mkdirSync, rmSync } from "node:fs";

const src = new URL("./src/", import.meta.url).pathname;
const out = new URL("./dist/", import.meta.url).pathname;
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
await build({
  entryPoints: [src + "app.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari15", "chrome100"],
  outfile: out + "app.js",
  legalComments: "eof",
});
copyFileSync(src + "index.html", out + "index.html");
copyFileSync(src + "app.css", out + "app.css");
copyFileSync(src + "editor/editor.css", out + "editor.css");
console.log("built", out);
